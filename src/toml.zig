const std = @import("std");

const debug = std.debug;
const mem = std.mem;

/// TOML has 3 data structures: value, array, table.
///  Each of them can have identification key.
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Array = struct {
    key: []const u8, // key to this array
    kind: u8, // element kind: 'v'alue, 'a'rray, or 't'able
    type: u8, // for value kind: 'i'nt, 'd'ouble, 'b'ool, 's'tring, 't'ime, 'D'ate, 'T'imestamp

    len: u32, // number of elements
    u: TomlType,
};

pub const Table = struct {
    key: []const u8, // key to this table
    implicit: bool, // table was created implicitly

    // key-values in the table
    pairs: []KeyValue,

    // arrays in the table
    arrays: []Array,

    // tables in the table
    tables: []Table,
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
    pointer: *u8, // points into context->start
    len: u32,
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

    path = struct {
        top: i32,
        key: [10]u8,
        token: [10]Token,
    },
};

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

const Date = struct {
    year: i32,
    month: i32,
    day: i32,
};

fn scan_date(p: []const u8) !Date {
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
//     var lineNum = context.token.lineNum;
//     var p = context.token.pointer;
//
//     // eat this token
//     var i: u32 = 0;
//     for (context.token) |token| {
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
