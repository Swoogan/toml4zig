const std = @import("std");

const debug = std.debug;
const mem = std.mem;

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

    if (buf[buf.len - 1] == '.')
    // if (p != buf && p[-1] == '.')
        return error.InvalidInput;

    // Run strtod on buf to get the value
    return std.fmt.parseFloat(f64, buf);
}

pub fn rawToDecimal(src: []const u8) !f64 {
    var buf: [100]u8 = undefined;
    return rawToDecimalExec(src, buf[0..99]);
}
