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
    
    char* p = buf;
    char* q = p + buflen;
    const char* s = src;
    double dummy;
    double* ret = ret_ ? ret_ : &dummy;
	

    // allow +/- */
	if (s[0] == '+' || s[0] == '-')
		*p++ = *s++;

	// disallow +_1.00 */
	if (s[0] == '_')
		return -1;

	// disallow +.99 */
	if (s[0] == '.')
		return -1;
		
	// zero must be followed by . or 'e', or NUL */
	if (s[0] == '0' && s[1] && !strchr("eE.", s[1]))
		return -1;

    // just strip underscores and pass to strtod */
    while (*s && p < q) {
        int ch = *s++;
		switch (ch) {
		case '.':
			if (s[-2] == '_') return -1;
			if (s[0] == '_') return -1;
			break;
		case '_':
			// disallow '__'
			if (s[0] == '_') return -1; 
			continue;			// skip _ */
		default:
			break;
		}
        *p++ = ch;
    }
    if (*s || p == q) return -1; // reached end of string or buffer is full? */
	
	// last char cannot be '_' */
	if (s[-1] == '_') return -1;

    if (p != buf && p[-1] == '.') 
        return -1; // no trailing zero */

    // cap with NUL */
    *p = 0;

    // Run strtod on buf to get the value */
    char* endp;
    errno = 0;
    *ret = strtod(buf, &endp);
    return (errno || *endp) ? -1 : 0;
}

pub fn rawToDecimal(src: []const u8) !f64 {
    var buf: [100]u8 = undefined;
    return rawToDecimalExec(src, buf[0..99]);
}
