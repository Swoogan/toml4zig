// MIT License
//
// Copyright (c) 2017 - 2019 CK Tan
// Translation to Zig, Copyright (c) 2020 Colin Svingen
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const os = @import("os");

const debug = std.debug;
const mem = std.mem;

// File I/O interface
pub const ReadError = os.ReadError;

pub fn read(self: File, buffer: []u8) ReadError!usize {
    return os.read(self.handle, buffer);
}

pub const WriteError = os.WriteError;

pub fn write(self: File, bytes: []const u8) WriteError!void {
    return os.write(self.handle, bytes);
}

/// TOML has 3 data structures: value, array, table.
///  Each of them can have identification key.
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Array = struct {
    key: []const u8, // key to this array
    kind: u8,        // element kind: 'v'alue, 'a'rray, or 't'able
    type: u8,        // for value kind: 'i'nt, 'd'ouble, 'b'ool, 's'tring, 't'ime, 'D'ate, 'T'imestamp

    len: u32,        // number of elements
    u: TomlType,
};

pub const Table = struct {
    key: []const u8,  // key to this table
    implicit: bool,   // table was created implicitly

    // key-values in the table
    pairs: std.ArrayList(KeyValue),

    // arrays in the table
    arrays: std.ArrayList(Array),

    // tables in the table
    tables: std.ArrayList(Table),

    fn init(allocator: *Allocator) !void {
        pairs.init(allocator);
        arrays.init(allocator);
        tables.init(allocator);
    }

    fn deinit() void {
        pairs.deinit();
        arrays.deinit();
        tables.deinit();
    }
};

pub const TomlType = union(enum) {
    pair: *KeyValue,
    array: *Array,
    table: *Table,
};


const TokenType = enum {
    INVALID,
    DOT,
    COMMA,
    EQUAL,
    LBRACE,
    RBRACE,
    NEWLINE,
    LBRACKET,
    RBRACKET,
    STRING,
};

const Token = struct {
    kind: TokenType,
    lineNumber: u32,
    slice: []const u8, // points into context.start
    eof: u32,
};

const Context = struct {
    start: []const u8,
    stop: []const u8,
    errorBuffer: []const u8,
    jmp: jmp_buf,

    token: Token,
    root: *Table,
    currentTable: *Table,

    allocator: *Allocator,

    path = struct {
        top: i32,
        key: [10]u8,
        token: [10]Token,
    },
};

const tabPath = struct {
    count: u32,
    key: [10]Token,
};

/// Create a keyval in the table.
fn createKeyValueInTable(context: *Context, table: *Table, keyToken: Token) !KeyValue {
    // first, normalize the key to be used for lookup.
    var newkey = normalizeKey(context, keyToken);
    errdefer context.allocator.free(newkey);

    // if key exists: error out
    if (keyKind(table, newkey)) {
        // e_key_exists_error(context, keyToken.lineNum, newkey);
        return error.KeyExists;
    }

    // make a new entry
    var len = table.pairs.len;
    var size = (len+1) * @sizeOf(KeyValue);

    var al = context.allocator;
    table.pairs = try al.realloc(table.pairs, size);

//    if (0 == (base[n] = (*keyval) CALLOC(1, sizeof(*base[n])))) {
//        xfree(newkey);
//        return error.OutOfMemory;
//    }

    // save the key in the new value struct
    var dest: *KeyValue = table.pairs[table.pairs.len-1];
    dest.key = newkey;
    return dest;
}


/// Create a table in the table.
fn createKeyTableInTable(context: *Context, table: *Table, keyToken: Token) !Table {
    // first, normalize the key to be used for lookup. 
    // remember to free it if we error out. 
     var newkey = normalizeKey(context, keyToken);
     errdefer context.allocator.free(newkey);

     var dest: *Table = undefined;

     // if key exists: error out
     if (checkKey(table, newkey, 0, 0, &dest)) {
        // special case: if table exists, but was created implicitly ...
        if (dest != undefined and dest.implicit) {
            // we make it explicit now, and simply return it
            dest.implicit = false;
            return dest;
        }

        // e_key_exists_error(context, keyToken.lineNum, newkey);
        return error.KeyExists;
    }

    // create a new table entry 
    // save the key in the new table struct
    var t = Table {
        .key = newkey
    };

    table.table.append(t);
        
    return t;
}

/// Create an array in the table.
fn createKeyArrayInTable(context: *Context, table: *Table, keytok: Token, kind: u8) !*Array {
    // first, normalize the key to be used for lookup. 
    // remember to free it if we error out. 
    var newkey = normalizeKey(context, keytok);
    errdefer context.allocator.free(newkey);
    
    // if key exists: error out 
    if (key_kind(tab, newkey)) {
        // e_key_exists_error(context, keytok.lineno, newkey);
        return error.KeyExists;
    }

    // make a new array entry
    // save the key in the new array struct
    var dest = Array {
        .key = newkey,
        .kind = kind,
    };

    table.array.append(dest);

    return dest;
}

/// Raw to boolean
pub fn rawToBool(src: []const u8) !bool {
    if (src.len == 0)
        return error.NoInput;

    if (mem.eql(u8, src, "true"))
        return true;

    if (mem.eql(u8, src, "false"))
        return false;

    return error.ConvertFailed;
}

test "boolean" {
    const f = try rawToBool("false");
    std.testing.expect(f == false);

    const t = try rawToBool("true");
    std.testing.expect(t == true);
}

/// Raw to integer
pub fn rawToInt(src: []const u8) !i64 {
    if (src.len == 0)
        return error.NoInput;

    var buf: [100]u8 = undefined;
    var j: u8 = 0;
    var i: u8 = 0;

    // allow +/-
    if (src[i] == '+' or src[i] == '-') {
        buf[j] = src[i];
        j += 1;
        i += 1;
    }

    // disallow +_100
    if (src[i] == '_')
        return error.InvalidInput;

    var base: u8 = 10;

    // if 0 ...
    if (src[i] == '0') {
        switch (src[i + 1]) {
            'x' => {
                base = 16;
                i += 2;
            },
            'o' => {
                base = 8;
                i += 2;
            },
            'b' => {
                base = 2;
                i += 2;
            },
            0 => {
                const zero: i64 = 0;
                return zero;
            },
            else => {
                // ensure no other digits after it
                if (src[i + 1] != '0') return error.InvalidInput;
            },
        }
    }

    // just strip underscores and pass to parseInt
    while (i < src.len and j < buf.len) {
        const ch = src[i];
        i += 1;

        switch (ch) {
            '_' => {
                if (i == src.len)
                    break;

                // disallow '__'
                if (src[i] == '_')
                    return error.InvalidInput;

                continue; // skip _
            },
            else => {
                buf[j] = ch;
                j += 1;
            },
        }
    }

    if (i < src.len or j == buf.len) return error.InvalidInput;

    // last char cannot be '_'
    if (src[src.len - 1] == '_') return error.InvalidInput;

    return std.fmt.parseInt(i64, buf[0..j], base);
}

test "integer" {
    var num = try rawToInt("33_45_456_24");
    std.testing.expect(num == 334545624);

    num = try rawToInt("+10");
    std.testing.expect(num == 10);

    num = try rawToInt("-10");
    std.testing.expect(num == -10);

    num = try rawToInt("0b11");
    std.testing.expect(num == 3);

    num = try rawToInt("0o10");
    std.testing.expect(num == 8);

    num = try rawToInt("0xA");
    std.testing.expect(num == 10);

    _ = rawToInt("__45") catch |err| {
        std.testing.expect(err == error.InvalidInput);
    };

    _ = rawToInt("_45_") catch |err| {
        std.testing.expect(err == error.InvalidInput);
    };
}

fn rawToDecimalExec(src: []const u8, buf: []u8) i32 {
    if (src.len == 0)
        return error.NoInput;

    var i: u8 = 0;
    var j: u8 = 0;

    // allow +/-
    if (src[i] == '+' or src[i] == '-') {
        buf[j] = src[i];
        j += 1;
        i += 1;
    }

    // disallow +_1.00
    if (src[i] == '_')
        return error.InvalidInput;

    // disallow +.99
    if (src[i] == '.')
        return error.InvalidInput;

    // zero must be followed by . or 'e', or NUL
    if (src[i] == '0' and src[i + 1] and !strchr("eE.", src[i + 1]))
        return error.InvalidInput;

    // just strip underscores and pass to strtod
    while (i < src.len and j < buf.len) {
        var ch = src[i];
        i += 1;

        switch (ch) {
            '.' => {
                // if (src[-2] == '_') return -1;
                if (src[i] == '_')
                    return error.InvalidInput;

                // break;
            },
            '_' => {
                // disallow '__'
                if (src[i] == '_')
                    return error.InvalidInput;

                // skip _
                continue;
            },
            else => {
                break;
            },
        }

        buf[j] = ch;
        j += 1;
    }

    // reached end of string or buffer is full?
    if (i == src.len or j == buf.len)
        return error.InvalidInput;

    // last char cannot be '_'
    if (src[src.len - 1] == '_')
        return error.InvalidInput;

    if (j == buf.len or p[j - 1] == '.')
        return error.InvalidInput;

    // Run strtod on buf to get the value
    return std.fmt.parseFloat(f64, buf);
}

pub fn rawToDecimal(src: []const u8) !f64 {
    var buf: [100]u8 = undefined;
    return rawToDecimalExec(src, buf[0..99]);
}

test "Decimal" {
    var num = try rawToInt("33_45_456_24");
    std.testing.expect(num == 334545624);
}

/// Look up key in table. Returns `NotFound` if not present,
/// or the element
fn check_key(table: *Table, key: []const u8) !TomlType {
    for (table.pairs) |*pair| {
        if (std.mem.eql(u8, key, pair.key)) {
            return TomlType{ .pair = pair };
        }
    }

    for (table.arrays) |array, i| {
        if (std.mem.eql(u8, key, array.key)) {
            return TomlType{ .array = &table.arrays[i] };
        }
    }

    for (table.tables) |tab, i| {
        if (std.mem.eql(u8, key, tab.key)) {
            return TomlType{ .table = &table.tables[i] };
        }
    }

    return error.NotFound;
}

test "check_key" {
    var pairs = [_]KeyValue{.{ .key = "a", .value = "v" }};
    var t = Table{
        .key = "key",
        .implicit = false,
        .pairs = pairs[0..pairs.len],
        .arrays = undefined,
        .tables = undefined,
    };
    var result = try check_key(&t, "a");
    switch (result) {
        TomlType.pair => |pair| std.testing.expect(std.mem.eql(u8, pair.value, "v")),
        else => unreachable,
    }
}

fn rawToString(src: []const u8) ![]const u8 {
    var multiline = false;

    var start: u8 = 0;
    var end: u8 = 0;

    if (src.len == 0)
        return error.InvalidInput;

    if (src[0] != '\'' and src[0] != '"')
        return error.InvalidInput;

    if (src[0] == '\'') {

        // TODO: bounds check here
        if (std.mem.eql(u8, src[0..3], "'''")) {
            multiline = true;
            start = 3;
            end = src.len - 3 - 1;

            if (start >= end)
                return error.InvalidInput;

            // last 3 chars in src must be '''
            if (std.mem.eql(u8, src[end .. src.len - 1], "'''"))
                return error.InvalidInput;

            // skip first new line right after '''
            if (src[start] == '\n') {
                start += 1;
            } else if (src[start] == '\r' and src[start + 1] == '\n') {
                start += 2;
            }

            return norm_lit_str(sp, sq - sp, multiline, 0, 0);
        } else {
            start = 1;
            end = src.len - 1;

            // last char in src must be '
            if (!(start <= end and src[end] == '\''))
                return invalid.Input;

            return src[start..end];
        }
    }

    if (std.mem.eql(u8, src[0..3], "\"\"\"")) {
        multiline = true;
        start = 3;
        end = src.len - 3 - 1;

        if (start >= end)
            return error.InvalidInput;

        if (std.mem.eql(u8, src[start..end], "\"\"\""))
            return error.InvalidInput;

        // skip first new line right after """
        if (src[start] == '\n') {
            start += 1;
        } else if (src[start] == '\r' and src[start + 1] == '\n') {
            start += 2;
        }

        return = norm_basic_str(sp, sq - sp, multiline, 0, 0);
    } else {
        start = 1;
        end = src.len - 1;

        if (start >= end)
            return invalidInput;

        if (end != '"')
            return invalidInput;

        return src[start..end];
    }
}

fn ret_eof(context: Context, lineNum: u32) TokenType {
    ret_token(context, NEWLINE, lineno, context.stop, 0);
    context.token.n.eof = 1;
    return context.token.n.token;
}

/// Scan p for n digits compositing entirely of [0-9]
fn scanDigits(src: []const u8, count: i32) i32 {
    var result = 0;
    var j = 0;

    while (count > 0 and isDigit(src[j])) {
        result = 10 * ret + atoi(src[j]);
        count -= 1;
        j += 1;
    }

    return if (n != 0) error.NonDigit else result;
}

const Date = struct {
    year: i32,
    month: i32,
    day: i32,
};

fn scanDate(p: []const u8) !Date {
    var year = scan_digits(p, 4);
    var month = if (year >= 0 and p[4] == '-') scan_digits(p + 5, 2) else -1;
    var day = if (month >= 0 and p[7] == '-') scan_digits(p + 8, 2) else -1;

    var date = Date{
        .year = year,
        .month = month,
        .day = day,
    };

    return if (day >= 0) date else error.NoDay;
}

const Time = struct {
    hour: i32,
    minute: i32,
    second: i32,
};

fn scanTime(p: []const u8) !Time {
    var hour = scanDigits(p, 2);
    var minute = if (hour >= 0 and p[2] == ':') scan_digits(p + 3, 2) else return error.NoHour;
    var second = if (minute >= 0 and p[5] == ':') scan_digits(p + 6, 2) else return error.NoMinute;

    var time = Time{
        .hour = hour,
        .minute = minute,
        .second = second,
    };

    return if (second >= 0) time else return error.NoSecond;
}

// fn nextToken(context: *Context, dotIsSpecial: bool) TokenType {
//     var lineNum = context.token.n.lineNum;
//     var p = context.token.n.pointer;
//
//     // eat this token
//     var i: u32 = 0;
//     for (context.token.n) |token| {
//         if (*p++ == '\n')
//             lineNum += 1;
//     }
//
//     // make next token
//     while (p < context.stop) {
//         // skip comment. stop just before the \n.
//         if (*p == '#') {
//             for (p++; p < context.stop && *p != '\n'; p++);
//             continue;
//         }
//
//         if (dotIsSpecial and *p == '.')
//             return ret_token(ctx, DOT, lineno, p, 1);
//
//         switch (*p) {
//         case ',': return ret_token(ctx, COMMA, lineno, p, 1);
//         case '=': return ret_token(ctx, EQUAL, lineno, p, 1);
//         case '{': return ret_token(ctx, LBRACE, lineno, p, 1);
//         case '}': return ret_token(ctx, RBRACE, lineno, p, 1);
//         case '[': return ret_token(ctx, LBRACKET, lineno, p, 1);
//         case ']': return ret_token(ctx, RBRACKET, lineno, p, 1);
//         case '\n': return ret_token(ctx, NEWLINE, lineno, p, 1);
//         case '\r': case ' ': case '\t':
//             // ignore white spaces
//             p++;
//             continue;
//         }
//
//         return scan_string(ctx, p, lineno, dotisspecial);
//     }
//
//     return ret_eof(ctx, lineno);
// }

fn keyIn(table: *Table, keyIndex: u32) ![]const u8 {
    if (keyidx < table.nkval)
        return table.kval[keyidx].key;

    keyidx -= table.nkval;
    if (keyidx < table.narr)
        return table.arr[keyidx].key;

    keyidx -= table.narr;
    if (keyidx < table.ntable)
        return table.table[keyidx].key;

    return error.NotFound;
}

fn rawIn(table: *Table, key: []const u8) ![]const u8 {
    var i: u32;
    return while (i < table.nkval) : (i += 1) {
        if (0 == strcmp(key, table.kval[i].key))
            break table.table[i];
    } else error.NotFound;
}

fn arrayIn(table: *Table, key: u8) !*Array {
    var i: u32;
    return while (i < table.narr) : (i += 1) {
        if (0 == strcmp(key, table.array[i].key))
            break table.table[i];
    } else error.NotFound;
}

fn tableIn(table: *Table, key: u8) !*Table {
    var i: u32;
    return while (i < table.ntab) : (i += 1) {
        if (0 == strcmp(key, table.table[i].key))
            break table.table[i];
    } else error.NotFound;
}

fn rawAt(array: *Array, index: u32) !*u8 {
    if (array.kind != 'v')
        return error.InvalidInput;

    if (!(0 <= index and index < array.len))
        return error.IndexOutOfBounds;

    // union type
    return array.TomlType.value[index];
}

fn arrayKind(array: *Array) u8 {
    return array.kind;
}

fn arrayType(array: *Array) u8 {
    if (array.kind != 'v')
        return error.InvalidInput;

    if (array.len == 0)
        return 0;

    return array.type;
}

fn arrayLen(array: *Array) i32 {
    return arr.len;
}

fn arrayKey(array: *Array) !*u8 {
    if (array == undefined)
        return error.Undefined; // TODO: can this even happen?

    return array.key;
}

fn tableNKval(table: *Table) i32 {
    return tab.nkval;
}

fn tableNArr(table: *Table) i32 {
    return table.narr;
}

fn tableNTab(table: *Table) i32 {
    return tab.ntab;
}

fn tableKey(table: *Table) !*u8 {
    if (table == undefined)
        return error.TableNotDefined;

    return table.key;
}

fn arrayAt(array: *Array, index: u32) !*Array {
    if (array.kind != 'a')
        return error.InvalidInput;

    if (!(0 <= index and index < array.len))
        return error.IndexNotInRange;

    return array.array[index];
}

fn tableAt(array: *Array, index: u32) !*Table {
    if (array.kind != 't')
        return error.InvalidInput;

    if (!(0 <= idx and idx < array.len))
        return error.IndexNotInRange;

    return array.Table[idx];
}


/// copy a string
fn copyString(allocator: *Allocator, source: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, source.len);
    errdefer allocator.free(result);
    mem.copy(u8, result, source);
    return result;
}


/// Convert a char in utf8 into UCS, and store it in *ret.
/// Return #bytes consumed or -1 on failure.
fn toml_utf8_to_ucs(orig: []const u8) !u64 {
    //var buf: const unsigned char* = (const unsigned char*) orig;
    var buf = 0;
    var i: u32 = 0;
    var result: u64 = 0;

   // 0x00000000 - 0x0000007F:
   // 0xxxxxxx

   if (0 == (i >> 7)) {
       if (orig.len < 1) 
           return error.InvalidInput;

       result = i;
       // return *ret = result, 1;
       return result;
   }

   // 0x00000080 - 0x000007FF:
   // 110xxxxx 10xxxxxx

    if (0x6 == (i >> 5)) {
       if (len < 2) return -1;
       result = i & 0x1f;
       {
           var j = 0;
           while (j < 1): (j+=1) {
               i = orig[buf];
               buf+=1;
               if (0x2 != (i >> 6)) return -1;
               result = (result << 6) | (i & 0x3f);
           }
       }
       // return result, ([]const u8*) buf - orig;
       return result;
    }

    // 0x00000800 - 0x0000FFFF:
    // 1110xxxx 10xxxxxx 10xxxxxx
        
    if (0xE == (i >> 4)) {
        if (len < 3) return -1;
        result = i & 0x0F;
        {
            var j = 0;
            while (j < 2): (j+=1) {
                i = orig[buf];
                buf+=1;
                if (0x2 != (i >> 6)) return -1;
                v = (v << 6) | (i & 0x3f);
            }
        }
        // return *ret = v, ([]const u8*) buf - orig;
        return result;
    }

    // 0x00010000 - 0x001FFFFF:
    // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        
    if (0x1E == (i >> 3)) {
        if (len < 4) return -1;
        result = i & 0x07;
        {
            var j = 0;
            while (j < 3): (j+=1) {
                i = orig[buf];
                buf+=1;
                if (0x2 != (i >> 6)) return -1;
                result = (result << 6) | (i & 0x3f);
            }
        }
        // return *ret = v, ([]const u8*) buf - orig;
        return result;
    }

    // 0x00200000 - 0x03FFFFFF:
    // 111110xx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx
        
    if (0x3E == (i >> 2)) {
        if (len < 5) return -1;
        result = i & 0x03;
        {
            var j = 0;
            while (j < 4): (j+=1) {
                i = orig[buf];
                buf+=1;
                if (0x2 != (i >> 6)) 
                    return error.InvalidInput;
                result = (result << 6) | (i & 0x3f);
            }
        }
        // return *ret = v, ([]const u8*) buf - orig;
        return result;
    }

    // 0x04000000 - 0x7FFFFFFF:
    // 1111110x 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx

    if (0x7e == (i >> 1)) {
        if (len < 6) return -1;
        result = i & 0x01;
        {
            var j = 0;
            while (j < 5): (j+=1) {
                i = orig[buf];
                buf+=1;
                if (0x2 != (i >> 6))
                    return error.InvalidInput;
                result = (result << 6) | (i & 0x3f);
            }
        }
        // return *ret = v, ([]const u8*) buf - orig;
        return result;
    }

    return error.InvalidInput;
}


///  Convert a UCS char to utf8 code, and return it in buf.
///  Return #bytes used in buf to encode the char, or 
///  -1 on error.
    
fn toml_ucs_to_utf8(code: i64, buf: [6]u8) !u8 {
    // http://stackoverflow.com/questions/6240055/manually-converting-unicode-codepoc_ints-c_into-utf-8-and-utf-16 
    // The UCS code values 0xd800–0xdfff (UTF-16 surrogates) as well
    // as 0xfffe and 0xffff (UCS noncharacters) should not appear in
    // conforming UTF-8 streams.
        
    if (0xd800 <= code and code <= 0xdfff) return -1;
    if (0xfffe <= code and code <= 0xffff) return -1;

    // 0x00000000 - 0x0000007F:
    // 0xxxxxxx

    if (code < 0)
        return error.InvalidInput;

    if (code <= 0x7F) {
        buf[0] = @intCast(u8, code);
        return 1;
    }

    // 0x00000080 - 0x000007FF:
    // 110xxxxx 10xxxxxx

    if (code <= 0x000007FF) {
        buf[0] = 0xc0 | (code >> 6);
        buf[1] = 0x80 | (code & 0x3f);
        return 2;
    }

    // 0x00000800 - 0x0000FFFF:
    // 1110xxxx 10xxxxxx 10xxxxxx

    if (code <= 0x0000FFFF) {
        buf[0] = 0xe0 | (code >> 12);
        buf[1] = 0x80 | ((code >> 6) & 0x3f);
        buf[2] = 0x80 | (code & 0x3f);
        return 3;
    }

    // 0x00010000 - 0x001FFFFF:
    // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx

    if (code <= 0x001FFFFF) {
        buf[0] = 0xf0 | (code >> 18);
        buf[1] = 0x80 | ((code >> 12) & 0x3f);
        buf[2] = 0x80 | ((code >> 6) & 0x3f);
        buf[3] = 0x80 | (code & 0x3f);
        return 4;
    }

    // 0x00200000 - 0x03FFFFFF:
    // 111110xx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx

    if (code <= 0x03FFFFFF) {
        buf[0] = 0xf8 | (code >> 24);
        buf[1] = 0x80 | ((code >> 18) & 0x3f);
        buf[2] = 0x80 | ((code >> 12) & 0x3f);
        buf[3] = 0x80 | ((code >> 6) & 0x3f);
        buf[4] = 0x80 | (code & 0x3f);
        return 5;
    }

    // 0x04000000 - 0x7FFFFFFF:
    // 1111110x 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx

    if (code <= 0x7FFFFFFF) {
        buf[0] = 0xfc | (code >> 30);
        buf[1] = 0x80 | ((code >> 24) & 0x3f);
        buf[2] = 0x80 | ((code >> 18) & 0x3f);
        buf[3] = 0x80 | ((code >> 12) & 0x3f);
        buf[4] = 0x80 | ((code >> 6) & 0x3f);
        buf[5] = 0x80 | (code & 0x3f);
        return 6;
    }

    return -1;
}


//static TokenType next_token(*Context* context, c_int dotisspecial);

// error routines. All these functions longjmp to context->jmp 
//fn e_outofmemory(*Context context, []const u8* fline) c_int {
//    snprc_intf(context->errbuf, context->errbufsz, "ERROR: out of memory (%s)", fline);
//    longjmp(context->jmp, 1);
//    return -1;
//}
//
//
//fn e_c_internal_error(*Context* context, []const u8* fline) c_int {
//    snprc_intf(context->errbuf, context->errbufsz, "c_internal error (%s)", fline);
//    longjmp(context->jmp, 1);
//    return -1;
//}
//
//fn e_syntax_error(*Context* context, c_int lineNum, []const u8* msg) c_int {
//    snprc_intf(context->errbuf, context->errbufsz, "line %d: %s", lineNum, msg);
//    longjmp(context->jmp, 1);
//    return -1;
//}
//
//fn e_bad_key_error(*Context* context, c_int lineNum) c_int {
//    snprc_intf(context->errbuf, context->errbufsz, "line %d: bad key", lineNum);
//    longjmp(context->jmp, 1);
//    return -1;
//}
//
//fn e_noimpl(*Context* context, []const u8* feature) c_int {
//    snprc_intf(context->errbuf, context->errbufsz, "not implemented: %s", feature);
//    longjmp(context->jmp, 1);
//    return -1;
//}
//
//fn e_key_exists_error(*Context* context, c_int lineNum, []const u8* key) c_int {
//    snprc_intf(context->errbuf, context->errbufsz,
//            "line %d: key %s exists", lineNum, key);
//    longjmp(context->jmp, 1);
//    return -1;
//}
 

fn norm_lit_str(allocator: *Allocator, src: []const u8, multiline: bool, errbuf: []const u8) []const u8 {
    var dst: []u8 = undefined;   // will write to dst[] and return it 
    var max: u16  = 0;           // max size of dst[] 
    var off: u16  = 0;           // cur offset in dst[] 
    var sp : u16  = 0;
    var sq : u16  = src.len;
    var ch : u8;

    dst = try allocator.alloc(u8, 50);
    errdefer allocator.free(dst);

    // scan forward on src 
    while (true) {
        if (off >=  max - 10) { // have some slack for misc stuff 
            max += 50;
            dst = try allocator.realloc(dst, max);
        }

        // finished? 
        if (sp >= sq) break; 

        ch = src[sp];
        sp += 1;
        // control characters other than tab is not allowed 
        if ((0 <= ch and ch <= 0x08)
                || (0x0a <= ch and ch <= 0x1f)
                || (ch == 0x7f)) {
            if (! (multiline and (ch == '\r' or ch == '\n'))) {
                snprc_intf(errbuf, errbufsz, "invalid char U+%04x", ch);
                return error.InvalidChar;
            }
        }

        // a plain copy suffice
        dst[off] = ch;
        off+=1;
    }

    dst[off] = 0;
    off+=1;
    return dst;
}


/// Convert src to raw unescaped utf-8 string.
/// Returns NULL if error with errmsg in errbuf.
    
fn norm_basic_str(src: []const u8, multiline: bool, errbuf: [*]u8, errbufsz: u32) ![]const u8 {
    var dst: []u8 = undefined;              // will write to dst[] and return it 
    var max: c_int   = 0;              // max size of dst[] 
    var off: c_int   = 0;              // cur offset in dst[] 
    var sp: u16 = 0;
    var sq: u16 = src.len;
    var ch: u8 = undefined;
    
    dst = try allocator.alloc(u8, 50);
    errdefer allocator.free(dst);

    // scan forward on src 
    while (true) {
        if (off >=  max - 10) { // have some slack for misc stuff 
            max += 50;
            dst = try allocator.realloc(dst, max);
        }

        // finished? 
        if (sp >= sq) break; 

        ch = src[sp];
        sp += 1;
        
        if (ch != '\\') {
            // these chars must be escaped: U+0000 to U+0008, U+000A to U+001F, U+007F 
            if ((0 <= ch and ch <= 0x08)
                    || (0x0a <= ch and ch <= 0x1f)
                    || (ch == 0x7f)) {
                if (! (multiline and (ch == '\r' or ch == '\n'))) {
                    snprc_intf(errbuf, errbufsz, "invalid char U+%04x", ch);
                    return error.InvalidChar;
                }
            }

            // a plain copy suffice
            dst[off] = ch;
            off += 1;
            continue;
        }

        // ch was backslash. we expect the escape char. 
        if (sp >= sq) {
            snprc_intf(errbuf, errbufsz, "last backslash is invalid");
            xfree(dst);
            return 0;
        }

        // for multi-line, we want to kill line-ending-backslash ... 
        if (multiline) {

            // if there is only whitespace after the backslash ...
            if (sp[strspn(sp, " \t\r")] == '\n') {
                // skip all the following whitespaces 
                sp += strspn(sp, " \t\r\n");
                continue;
            }
        }

        // get the escaped char 
        ch = src[sp];
        sp += 1;
        switch (ch) {
            'u' or 'U' =>
            {
                var ucs: c_int64_t = 0;
                var nhex: c_int = if (ch == 'u') 4 else 8;
                {
                    var i = 0;

                    while (i < nhex) : (i+=1) {
                        if (sp >= sq) {
                            snprc_intf(errbuf, errbufsz, "\\%c expects %d hex chars", ch, nhex);
                            return 0;
                        }

                        ch = src[sp];
                        sp += 1;
                        var v: c_int = if ('0' <= ch and ch <= '9')
                            ch - '0'
                        else (if ('A' <= ch and ch <= 'F')  ch - 'A' + 10 else -1);

                        if (-1 == v) {
                            snprc_intf(errbuf, errbufsz, "invalid hex chars for \\u or \\U");
                            return 0;
                        }
                        ucs = ucs * 16 + v;
                    }
                }
                var n: c_int = toml_ucs_to_utf8(ucs, &dst[off]);
                if (-1 == n) {
                    snprc_intf(errbuf, errbufsz, "illegal ucs code in \\u or \\U");
                    xfree(dst);
                    return 0;
                }
                off += n;
                continue;
            },

            'b' => ch = 0x08,
            't' => ch = '\t',
            'n' => ch = '\n',
            'f' => ch = 0x0C,
            'r' => ch = '\r',
            '"' =>  ch = '"',
            '\\' => ch = '\\',
            else => { 
                snprc_intf(errbuf, errbufsz, "illegal escape char \\%c", ch);
                return 0;
            }
        }

        dst[off] = ch;
        off += 1;
    }

    // Cap with NUL and return it.
    dst[off] = 0; 
    off += 1;
    return dst;
}


/// Normalize a key. Convert all special chars to raw unescaped utf-8 chars. 
fn normalizeKey(context: *Context, strtok: Token) []const u8 {
    var str = strtok.slice;
    var lineNum = strtok.lineNum;
    var ret: []const u8 = undefined;
    var ebuf: [80]u8;

    var i: u32 = 0;
    var ch: u8 = str[0];

    // handle quoted string 
    if (ch == '\'' or ch == '\"') {
        // if ''' or """, take 3 chars off front and back. Else, take 1 char off. 
        var multiline: bool = false;
        if (str[1] == ch and str[2] == ch)  {
            i += 3; j -= 3;
            multiline = true;
        }
        else {
            i += 1; j -= 1;
        }

        if (ch == '\'') {
            // for single quote, take it verbatim. 
            try ret = STRNDUP(str, i, j);
        } 
        else {
            // for double quote, we need to normalize 
            ret = norm_basic_str(sp, sq - sp, multiline, ebuf, sizeof(ebuf));
            if (!ret) {
                snprc_intf(context.errbuf, context.errbufsz, "line %d: %s", lineNum, ebuf);
                longjmp(context.jmp, 1);
            }
        }

        // newlines are not allowed in keys 
        if (strchr(ret, '\n')) {
            xfree(ret);
            e_bad_key_error(context, lineNum);
            return 0;           // not reached 
        }
        return ret;
    }

    // for bare-key allow only this regex: [A-Za-z0-9_-]+ 
    var xp = sp;
    while (xp != sq) : (xp += 1) {
        var k = xp;

        if (isalnum(k)) 
            continue;

        if (k == '_' or k == '-') 
            continue;

        e_bad_key_error(context, lineNum);
        return error.BadKey;
    }

    // dup and return it 
    ret = try STRNDUP(sp, sq - sp);

    return ret;
}

fn key_kind(tab: *Table, key: []const u8) c_int {
    return check_key(tab, key, 0, 0, 0);
}

/// Create an array in an array 
    
fn create_array_in_array(context: *Context, parent: *Array) *Array {
//    var n: c_int = parent.len;
//    var base: *Array = undefined;
//    if (0 == (base = (*Array*) REALLOC(parent->u.arr, (n+1) * sizeof(*base)))) {
//        e_outofmemory(context, FLINE);
//        return 0;               // not reached 
//    }
//    parent->u.arr = base;
//
//    if (0 == (base[n] = (*Array) CALLOC(1, sizeof(*base[n])))) {
//        e_outofmemory(context, FLINE);
//        return 0;               // not reached 
//    }
//
//    return parent->u.arr[parent->nelem++];
    var a = Array {};
    parent.u.array.append(a);
}

/// Create a table in an array 
    
fn create_table_in_array(context: *Context, parent: *Array) *Table {
//    c_int n = parent->nelem;
//    var base: **Table = undefined;
//
//    if (0 == (base = (*Table) REALLOC(parent->u.tab, (n+1) * sizeof(*base)))) {
//        // e_outofmemory(context, FLINE);
//        return error.OutOfMemory; 
//    }
//    parent->u.tab = base;
//
//    if (0 == (base[n] = (*Table) CALLOC(1, sizeof(*base[n])))) {
//        // e_outofmemory(context, FLINE);
//        return error.OutOfMemory;
//    }
//
//    return parent->u.tab[parent->nelem++];
    var table = Table {};
    parent.u.table.append(table);
    return &table;
}


fn SKIP_NEWLINES(context: *Context, is_dot_special: bool) void {
    while (context.token.n.token == NEWLINE) {
        next_token(context, is_dot_special);
    }
}

fn EAT_TOKEN(context: *Context, kind: TokenType, is_dot_special: bool) void {
    if (context.token.n.kind != kind) {
        e_c_internal_error(context, FLINE); 
    }
    else {
        next_token(context, is_dot_special);
    }
}


/// We are at '{ ... }'.
/// Parse the table.
    
fn parse_table(context: *Context, table: *Table) void {
    EAT_TOKEN(context, LBRACE, 1);

    while (true) {
        if (context.token.n.kind == NEWLINE) {
            e_syntax_error(context, context.token.n.lineNum, "newline not allowed in inline table");
            return error.SyntaxError;
        }

        // until } 
    if (context.token.n.kind == RBRACE) break;

    if (context.token.n.kind != STRING) {
        e_syntax_error(context, context.token.n.lineNum, "syntax error");
        return;             // not reached 
    }
    parse_keyval(context, tab);

    if (context.token.n.kind == NEWLINE) {
        e_syntax_error(context, context.token.n.lineNum, "newline not allowed in inline table");
        return;				// not reached 
    }

    // on comma, continue to scan for next keyval 
    if (context.token.n.kind == COMMA) {
        EAT_TOKEN(context, COMMA, 1);
        continue;
    }
    break;
}

if (context.token.n.tok != RBRACE) {
    e_syntax_error(context, context.token.n.lineNum, "syntax error");
    return;                 // not reached 
}

EAT_TOKEN(context, RBRACE, 1);
}

fn valtype(val: []const u8) u8 {

    if (val[0] == '\'' or val[0] == '"') return 's';
    if (0 == toml_rtob(val, 0)) return 'b';
    if (0 == toml_rtoi(val, 0)) return 'i';
    if (0 == toml_rtod(val, 0)) return 'd';

    var ts: Timestamp = undefined;
    if (0 == toml_rtots(val, &ts)) {
        if (ts.year and ts.hour) return 'T'; // timestamp 
        if (ts.year) return 'D'; // date 
        return 't'; // time 
    }
    return 'u'; // unknown 
}


// We are at '[...]' 
fn parse_array(context: *Context, array: *Array) void {
    EAT_TOKEN(context, LBRACKET, 0);

    while (true) {
        SKIP_NEWLINES(context, 0);

        // until ] 
        if (context.token.n.kind == RBRACKET) break;

        switch (context.token.n.kind) {
            STRING =>
                {
                    var val = context.token.n.slice;
                    var vlen = context.token.n.len;

                    // set array kind if this will be the first entry 
                    if (array.kind == 0) arr.kind = 'v';
                    // check array kind 
                    if (arr.kind != 'v') {
                        e_syntax_error(context, context.token.n.lineNum,
                                "a string array can only contain strings");
                        return error.SyntaxError;
                    }

                    // TODO: make a new value in array 
//                    char** tmp = (char**) REALLOC(arr.u.val, (arr.nelem+1) * sizeof(*tmp));
//                    if (!tmp) {
//                        e_outofmemory(context, FLINE);
//                        return;     // not reached 
//                    }
//                    arr.u.val = tmp;
//                    if (! (val = STRNDUP(val, vlen))) {
//                        e_outofmemory(context, FLINE);
//                        return;     // not reached 
//                    }
//                    arr.u.val[arr.nelem++] = val;

                    // set array type if this is the first entry, or check that the types matched. 
                    if (array.len == 1) {
                        array.type = valtype(array.u.val[0]);
                    }
                    else if (array.type != valtype(val)) {
                        e_syntax_error(context, context.token.n.lineNum,
                                "array type mismatch while processing array of values");
                        return error.SyntaxError;
                    }

                    EAT_TOKEN(context, STRING, 0);
                    break;
                },

            LBRACKET =>
                { // [ [array], [array] ... ] 
                    // set the array kind if this will be the first entry 
                    if (arr.kind == 0) arr.kind = 'a';
                    // check array kind 
                    if (arr.kind != 'a') {
                        e_syntax_error(context, context.token.n.lineNum,
                                "array type mismatch while processing array of arrays");
                        return error.SyntaxError;
                    }
                    parse_array(context, create_array_in_array(context, arr));
                    break;
                },

            LBRACE =>
                { // [ {table}, {table} ... ] 
                    // set the array kind if this will be the first entry 
                    if (arr.kind == 0) arr.kind = 't';
                    // check array kind 
                    if (arr.kind != 't') {
                        e_syntax_error(context, context.token.n.lineNum,
                                "array type mismatch while processing array of tables");
                        return error.SyntaxError;
                    }
                    parse_table(context, create_table_in_array(context, arr));
                    break;
                },

            else => {
                e_syntax_error(context, context.token.n.lineNum, "syntax error");
                        return error.SyntaxError;
            }
        }

        SKIP_NEWLINES(context, 0);

        // on comma, continue to scan for next element 
        if (context.token.n.kind == COMMA) {
            EAT_TOKEN(context, COMMA, 0);
            continue;
        }
        break;
    }

    if (context.token.n.kind != RBRACKET) {
        e_syntax_error(context, context.token.n.lineNum, "syntax error");
        return;                 // not reached 
    }

    EAT_TOKEN(context, RBRACKET, 1);
}


// handle lines like these:
// key = "value"
// key = [ array ]
// key = { table }
    
fn parse_keyval(context: *Context, tab: *Table) void {
    var key = context.token.n;
    EAT_TOKEN(context, STRING, 1);

    if (key.kind == DOT) {
        // handle inline dotted key. 
        // e.g. 
        // physical.color = "orange"
        // physical.shape = "round"
            
            var subtab: *Table  = undefined;
        {
            var subtabstr = normalizeKey(context, key);
            subtab = toml_table_in(tab, subtabstr);
            xfree(subtabstr);
        }
        if (!subtab) {
            subtab = create_keytable_in_table(context, tab, key);
        }
        next_token(context, 1);
        parse_keyval(context, subtab);
        return;
    }

    if (context.token.n.kind != EQUAL) {
        e_syntax_error(context, context.token.n.lineNum, "missing =");
        return;                 // not reached 
    }

    next_token(context, 0);

    switch (context.token.n.kind) {
        STRING =>
            { // key = "value" 
                var keyval: *Keyval = create_keyval_in_table(context, tab, key);
                var val: *KeyValue = context.token.n;
                assert(keyval.value == 0);
                keyval.value = STRNDUP(val.ptr, val.len);
                if (! keyval.value) {
                    e_outofmemory(context, FLINE);
                    return error.OutOfMemory; 
                }

                next_token(context, 1);
                return;
            },

        LBRACKET => 
            { // key = [ array ] 
                var array: *Array = create_keyarray_in_table(context, tab, key, 0);
                parse_array(context, arr);
                return;
            },

        LBRACE =>
            { // key = { table } 
                var nxttab: *Table = create_keytable_in_table(context, tab, key);
                parse_table(context, nxttab);
                return;
            },

        else => {
            e_syntax_error(context, context.token.n.lineNum, "syntax error");
                        return error.SyntaxError;
        }
    }
}


// at [x.y.z] or [[x.y.z]]
/// Scan forward and fill tabpath until it enters ] or ]]
/// There will be at least one entry on return.
    
fn fill_tabpath(context: *Context) void {
    var lineNum = context.token.n.lineNum;
    var i = 0;

    // clear tpath 
    while (i < context.tpath.top) : (i+=1) {
        char** p = &context.tpath.key[i];
        xfree(*p);
        *p = 0;
    }
    context.tpath.top = 0;

    while (true) {
        if (context.tpath.top >= 10) {
            e_syntax_error(context, lineNum, "table path is too deep; max allowed is 10.");
                        return error.SyntaxError;
        }

        if (context.token.n.kind != STRING) {
            e_syntax_error(context, lineNum, "invalid or missing key");
                        return error.SyntaxError;
        }

        context.tpath.tok[context.tpath.top] = context.token.n;
        context.tpath.key[context.tpath.top] = normalizeKey(context, context.token.n);
        context.tpath.top += 1;

        next_token(context, 1);

        if (context.token.n.kind == RBRACKET) break;

        if (context.token.n.kind != DOT) {
            e_syntax_error(context, lineNum, "invalid key");
            return;             // not reached 
        }

        next_token(context, 1);
    }

    if (context.tpath.top <= 0) {
        e_syntax_error(context, lineNum, "empty table selector");
        return;                 // not reached 
    }
}


// Walk tabpath from the root, and create new tables on the way.
// Sets context->curtab to the final table.
    
fn walk_tabpath(context: *Context) void {
    // start from root 
    var curtab: *Table = context.root;

    var i: u32 = 0;
    while (i < context.tpath.top) : (i += 1) {
        var key: []const u8 = context.tpath.key[i];

        var nextval: *KeyValue = 0;
        var nextarr: *Array = 0;
        var nexttab: *Table = 0;

        switch (check_key(curtab, key, &nextval, &nextarr, &nexttab)) {
            't' => {
                // found a table. nexttab is where we will go next. 
                break;
            },
            'a' => {
                // found an array. nexttab is the last table in the array. 
                if (nextarr.kind != 't') {
                    e_c_internal_error(context, FLINE);
                    return error.InternalError;
                }
                if (nextarr.nelem == 0) {
                    e_c_internal_error(context, FLINE);
                    return error.InternalError;
                }
                nexttab = nextarr.u.tab[nextarr.nelem-1];
                break;
            },
            'v' => {
                e_key_exists_error(context, context.tpath.tok[i].lineNum, key);
                return error.KeyExists;
            },
            else => { // Not found. Let's create an implicit table. 
                    var n = curtab.ntab;
                    var base: *Table = try context.allocator.alloc(Table);
//                     if (0 == base) {
//                         e_outofmemory(context, FLINE);
//                         return error.OutOfMemory; 
//                     }
                    curtab.table = base;
                    // base = 

//                     if (0 == (base[n] = (*Table) CALLOC(1, sizeof(*base[n])))) {
//                         e_outofmemory(context, FLINE);
//                         return error.OutOfMemory; 
//                     }

                    base[n].key = try STRDUP(key);
//                  e_outofmemory(context, FLINE);
//                  return error.OutOfMemory; 

                    nexttab = curtab.tab[curtab.ntab];
                    curtab.ntab += 1;

                    // tabs created by walk_tabpath are considered implicit 
                    nexttab.implicit = 1;
                }
        }

        // switch to next tab 
        curtab = nexttab;
    }

    // save it 
    context.curtab = curtab;
}


// handle lines like [x.y.z] or [[x.y.z]] 
fn parse_select(context: *Context) void {
    assert(context.token.en.kind == LBRACKET);

    // true if [[ 
    var llb: c_int = (context.token.ptr + 1 < context.stop and context.token.ptr[1] == '[');
    // need to detect '[[' on our own because next_token() will skip whitespace, 
    // and '[ [' would be taken as '[[', which is wrong. 

        // eat [ or [[ 
        EAT_TOKEN(context, LBRACKET, 1);
    if (llb) {
        assert(context.token.n.kind == LBRACKET);
        EAT_TOKEN(context, LBRACKET, 1);
    }

    fill_tabpath(context);

    // For [x.y.z] or [[x.y.z]], remove z from tpath. 
    
        var z: Token = context.tpath.tok[context.tpath.top-1];
    xfree(context.tpath.key[context.tpath.top-1]);
    context.tpath.top -= 1;

    // set up context.curtab 
    walk_tabpath(context);

    if (! llb) {
        // [x.y.z] . create z = {} in x.y 
        context.curtab = create_keytable_in_table(context, context.curtab, z);
    } else {
        // [[x.y.z]] . create z = [] in x.y 
        var arr: *Array = undefined;
        {
            var zstr: []const u8 = normalizeKey(context, z);
            arr = toml_array_in(context.curtab, zstr);
            xfree(zstr);
        }
        if (!arr) {
            arr = create_keyarray_in_table(context, context.curtab, z, 't');
            if (!arr) {
                e_c_internal_error(context, FLINE);
                return;
            }
        }
        if (arr.kind != 't') {
            e_syntax_error(context, z.lineNum, "array mismatch");
            return error.SyntaxError;
        }

        // add to z[] 
        var dest: *Table = undefined;
        {
//             var n = arr.len;
//             var base: *Table = REALLOC(arr.u.tab, (n+1) * sizeof(*base));
//             if (0 == base) {
//                 e_outofmemory(context, FLINE);
//                 return error.OutOfMemory; 
//             }
//             arr.u.tab = base;
// 
//             if (0 == (base[n] = CALLOC(1, sizeof(*base[n])))) {
//                 e_outofmemory(context, FLINE);
//                 return error.OutOfMemory; 
//             }
// 
//             if (0 == (base[n].key = STRDUP("__anon__"))) {
//                 e_outofmemory(context, FLINE);
//                 return error.OutOfMemory; 
//             }

            var n = arr.len;
            arr.u.tab = base;
            dest = arr.u.tab[arr.len];
            arr.len += 1;
        }

        context.curtab = dest;
    }

    if (context.token.n.kind != RBRACKET) {
        e_syntax_error(context, context.token.lineNum, "expects ]");
        return error.SyntaxError;
    }
    if (llb) {
        if (! (context.token.ptr + 1 < context.stop and context.token.ptr[1] == ']')) {
            e_syntax_error(context, context.token.lineNum, "expects ]]");
            return error.SyntaxError;
        }
        EAT_TOKEN(context, RBRACKET, 1);
    }
    EAT_TOKEN(context, RBRACKET, 1);

    if (context.token.n.kind != NEWLINE) {
        e_syntax_error(context, context.token.lineNum, "extra chars after ] or ]]");
        return;                 // not reached 
    }
}


fn parse(conf: []const u8, errbuf: []const u8, errbufsz: c_int) *Table {
    var context: *Context = undefined;

    // clear errbuf 
    if (errbufsz <= 0) errbufsz = 0;
    if (errbufsz > 0)  errbuf[0] = 0;

    // init context 
    memset(&context, 0, sizeof(context));
    context.start = conf;
    context.stop = context.start + strlen(conf);
    context.errbuf = errbuf;
    context.errbufsz = errbufsz;

    // start with an artificial newline of length 0
    context.token.n.kind = NEWLINE; 
    context.token.lineNum = 1;
    context.token.ptr = conf;
    context.token.len = 0;

    // make a root table
//     if (0 == (context.root = CALLOC(1, sizeof(*context.root)))) {
//         // do not call outofmemory() here... setjmp not done yet 
//         snprc_intf(context.errbuf, context.errbufsz, "ERROR: out of memory (%s)", FLINE);
//         return 0;
//     }

    // set root as default table
    context.curtab = context.root;

    if (0 != setjmp(context.jmp)) {
        // Got here from a long_jmp. Something bad has happened.
        // Free resources and return error.
        var i = 0;
        while (i < context.tpath.top) : (i+=1) xfree(context.tpath.key[i]);
        toml_free(context.root);
        return 0;
    }

    // Scan forward until EOF 
    var token = context.token.n;
    while (!token.eof) : (token = context.token.n) {
        switch (token.token) {

            NEWLINE => {
                next_token(&context, 1);
                break;
            },

            STRING => {
                parse_keyval(&context, context.curtab);
                if (context.token.n.token != NEWLINE) {
                    e_syntax_error(&context, context.token.n.lineNum, "extra chars after value");
                    return 0;         // not reached 
                }

                EAT_TOKEN(&context, NEWLINE, 1);
                break;
            },
            // [ x.y.z ] or [[ x.y.z ]] 
            LBRACKET => {
                parse_select(&context);
                break;
            },
            default => {
                snprc_intf(context.errbuf, context.errbufsz, "line %d: syntax error", token.lineNum);
                longjmp(context.jmp, 1);
            }
        }
    }

    // success 
    var i = 0;
    while (i < context.tpath.top) : (i+=1) xfree(context.tpath.key[i]);
    return context.root;
}

// const TomlParser = struct {


fn parseFile(allocator: *Allocator, errbuf: []const u8) *Table {
    var buffer: [*]u8 = undefined;
    var offset: u32 = 0;

    // prime the buf[] 
    var buffer_size = 1000;
    var buffer = try allocator.alloc(u8, buffer_size)
    catch |err| {
        snprc_intf(errbuf, errbufsz, "out of memory");
        return err;
    };

    // read from fp c_into buf 
    while (! feof(fp)) {
        bufsz += 1000;

        // Allocate 1 extra byte because we will tag on a NUL 
        char* x = REALLOC(buf, bufsz + 1);
        if (!x) {
            // snprc_intf(errbuf, errbufsz, "out of memory");
            xfree(buf);
            return error.OutOfMemory; 
        }
        buf = x;

        errno = 0;
        var n: c_int = fread(buf + off, 1, bufsz - off, fp);
        if (ferror(fp)) {
            snprc_intf(errbuf, errbufsz, "%s",
                    if (errno) strerror(errno) else "Error reading file");
            xfree(buf);
            return 0;
        }
        off += n;
    }

    // tag on a NUL to cap the string 
    buf[off] = 0; // we accounted for this byte in the REALLOC() above. 

    // parse it, cleanup and finish 
    var ret: *Table = parse(buf, errbuf, errbufsz);
    xfree(buf);
    return ret;
}


fn xfree_kval(p: *KeyValue) void {
    if (!p) return;
    xfree(p.key);
    xfree(p.value);
    xfree(p);
}

fn xfree_arr(p: *Array) void {
    if (!p) return;

    xfree(p.key);
    switch (p.kind) {
        'v' => {
            var i = 0;
            while (i < p.len) : (i+=1) xfree(p.u.value[i]);
            xfree(p.u.val);
            break;
        },

        'a' => {
            while (i < p.len) : (i+=1) xfree(p.u.array[i]);
            xfree(p.u.arr);
            break;

        },
        't' => {
            while (i < p.len) : (i+=1) xfree(p.u.table[i]);
            xfree(p.u.tab);
            break;
        }
    }

    xfree(p);
}


fn xfree_tab(p: *Table) void {
    var i: c_int = undefined;

    if (!p) return;

    xfree(p.key);

    while (i < p.nkval) : (i+=1) xfree(p.u.kval[i]);
    xfree(p.kval);

    while (i < p.narr) : (i+=1) xfree(p.u.karr[i]);
    xfree(p.arr);

    while (i < p.ntab) : (i+=1) xfree(p.u.ktab[i]);
    xfree(p.tab);

    xfree(p);
}

fn toml_free(table: *Table) void {
    xfree_tab(table);
}

fn ret_token(context: *Context, token: TokenType, lineNum: u32, slice: []const u8, len: u32) TokenType {
    var t = Token {
        .token = token,
        .lineNum = lineNum,
        .slice = slice,
        .len = len,
        .eof = 0,
    };
    context.token.n = t;
    return t;
}


fn scan_string(context: *Context, p: []const u8, lineNum: u32, dot_is_special: bool) TokenType {
    var orig: []const u8 = p;

    if (0 == strncmp(p, "'''", 3)) {
        p = strstr(p + 3, "'''");
        if (0 == p) {
            e_syntax_error(context, lineNum, "unterminated triple-s-quote");
            return error.SyntaxError;
        }

        return ret_token(context, STRING, lineNum, orig, p + 3 - orig);
    }

    if (0 == strncmp(p, "\"\"\"", 3)) {
        var hexreq: c_int = 0;         // #hex required 
        var escape: c_int = 0;
        var qcnt: c_int = 0;           // count quote 
        p += 3;
        while (*p and qcnt < 3) : (p+=1) {
            if (escape) {
                escape = 0;
                if (strchr("btnfr\"\\", *p)) continue;
                if (*p == 'u') { hexreq = 4; continue; }
                if (*p == 'U') { hexreq = 8; continue; }
                if (p[strspn(p, " \t\r")] == '\n') continue; // allow for line ending backslash 
                e_syntax_error(context, lineNum, "bad escape char");
                return error.SyntaxError;
            }
            if (hexreq) {
                hexreq-=1;
                if (strchr("0123456789ABCDEF", *p)) continue;
                e_syntax_error(context, lineNum, "expect hex char");
                return error.SyntaxError;
            }
            if (*p == '\\') { escape = 1; continue; }
            qcnt = if (*p == '"') qcnt + 1 else 0; 
        }
        if (qcnt != 3) {
            e_syntax_error(context, lineNum, "unterminated triple-quote");
            return 0;           // not reached 
        }

        return ret_token(context, STRING, lineNum, orig, p - orig);
    }

    if ('\'' == *p) {
        p += 1;
        while (*p and *p != '\n' and *p != '\'') {p+=1;}
        if (*p != '\'') {
            e_syntax_error(context, lineNum, "unterminated s-quote");
            return 0;           // not reached 
        }

        return ret_token(context, STRING, lineNum, orig, p + 1 - orig);
    }

    if ('\"' == *p) {
        var hexreq: c_int = 0;         // #hex required 
        var escape: c_int = 0;
        for (p++; *p; p++) {
            if (escape) {
                escape = 0;
                if (strchr("btnfr\"\\", *p)) continue;
                if (*p == 'u') { hexreq = 4; continue; }
                if (*p == 'U') { hexreq = 8; continue; }
                e_syntax_error(context, lineNum, "bad escape char");
                return 0;       // not reached 
            }
            if (hexreq) {
                hexreq--;
                if (strchr("0123456789ABCDEF", *p)) continue;
                e_syntax_error(context, lineNum, "expect hex char");
                return 0;       // not reached 
            }
            if (*p == '\\') { escape = 1; continue; }
            if (*p == '\n') break;
            if (*p == '"') break;
        }
        if (*p != '"') {
            e_syntax_error(context, lineNum, "unterminated quote");
            return 0;           // not reached 
        }

        return ret_token(context, STRING, lineNum, orig, p + 1 - orig);
    }

    // check for timestamp without quotes 
    if (0 == scan_date(p, 0, 0, 0) || 0 == scan_time(p, 0, 0, 0)) {
        // forward thru the timestamp
        for ( ; strchr("0123456789.:+-T Z", toupper(*p)); p++);
        // squeeze out any spaces at end of string
        for ( ; p[-1] == ' '; p--);
        // tokenize
        return ret_token(context, STRING, lineNum, orig, p - orig);
    }

    // literals 
    for ( ; *p and *p != '\n'; p++) {
        var ch: c_int = *p;
        if (ch == '.' and dotisspecial) break;
        if ('A' <= ch and ch <= 'Z') continue;
        if ('a' <= ch and ch <= 'z') continue;
        if (strchr("0123456789+-_.", ch)) continue;
        break;
    }

    return ret_token(context, STRING, lineNum, orig, p - orig);
}



fn toml_rtots(src_: []const u8*, ret: *timestamp) c_int {
    if (! src_) return -1;

    var p: []const u8* = src_;
    var must_parse_time: c_int = 0;

    memset(ret, 0, sizeof(*ret));

    var year: c_int* = &ret->__buffer.year;
    var month: c_int* = &ret->__buffer.month;
    var day: c_int* = &ret->__buffer.day;
    var hour: c_int* = &ret->__buffer.hour;
    var minute: c_int* = &ret->__buffer.minute;
    var second: c_int* = &ret->__buffer.second;
    var millisec: c_int* = &ret->__buffer.millisec;

    // parse date YYYY-MM-DD 
    if (0 == scan_date(p, year, month, day)) {
        ret->year = year;
        ret->month = month;
        ret->day = day;

        p += 10;
        if (*p) {
            // parse the T or space separator
            if (*p != 'T' and *p != ' ') return -1;
            must_parse_time = 1;
            p++;
        }
    }

    // parse time HH:MM:SS 
    if (0 == scan_time(p, hour, minute, second)) {
        ret.hour   = hour;
        ret.minute = minute;
        ret.second = second;

        // optionally, parse millisec 
        p += 8;
        if (*p == '.') {
            var qq: char*;
            p++;
            errno = 0;
            *millisec = strtol(p, &qq, 0);
            if (errno) {
                return -1;
            }
            while (*millisec > 999) {
                *millisec /= 10;
            }

            ret.millisec = millisec;
            p = qq;
        }

        if (*p) {
            // parse and copy Z 
            var z: char* = ret.__buffer.z;
            ret.z = z;
            if (*p == 'Z' || *p == 'z') {
                *z++ = 'Z'; p++;
                *z = 0;

            } else if (*p == '+' || *p == '-') {
                *z++ = *p++;

                if (! (isdigit(p[0]) and isdigit(p[1]))) return -1;
                *z++ = *p++;
                *z++ = *p++;

                if (*p == ':') {
                    *z++ = *p++;

                    if (! (isdigit(p[0]) and isdigit(p[1]))) return -1;
                    *z++ = *p++;
                    *z++ = *p++;
                }

                *z = 0;
            }
        }
    }
    if (*p != 0)
        return -1;

    if (must_parse_time and !ret.hour)
        return -1;

    return 0;
}


