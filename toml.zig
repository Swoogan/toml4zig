usingnamespace @cImport({
    @cInclude("string.h");
});

// Raw to boolean
export fn toml_rtob(src: [*c]const u8, ret_: *c_int) c_int {
    // if (!src) return -1;
    // if (src.len == 0) return -1;
    var dummy: c_int = undefined;
    var ret: *c_int = if (ret_ != undefined) ret_ else &dummy;

    if (0 == strcmp(src, "true")) {
        *ret = 1;
        return 0;
    }

    if (0 == strcmp(src, "false")) {
        *ret = 0;
        return 0;
    }

    return -1;
}

// Raw to integer
export fn toml_rtoi(src: [*:0]const u8, ret_: *i64) c_int {
    // if (!src) return -1;
    
    var buf: [100]u8 = undefined;
    //var char* p = buf;
    var p = &buf;
    // char* q = p + sizeof(buf);
    var q: [*]u8 = p + buf.len;
    const s = src;
    var base: c_int = 0;
    var dummy: i64 = undefined;
    var ret = if (ret_ != undefined) ret_ else &dummy;

    // allow +/-
    if (s[0] == '+' or s[0] == '-') {
        *p = *s;
        p += 1;
        s += 1;
    } 
    
    // disallow +_100 
    if (s[0] == '_')
        return -1;

    // if 0 ... 
    if ('0' == s[0]) {
        switch (s[1]) {
            'x' => { 
                base = 16; s += 2;
            },
            'o' => {
                base = 8; s += 2;
            },
            'b' => {
                base = 2; s += 2;
            },
            '\0' => {
                return *ret = 0, 0;
            }, 
            else => {
                // ensure no other digits after it 
                if (s[1]) return -1;
            }
        }
    }

    // just strip underscores and pass to strtoll
    while (*s && p < q) {
        int ch = *s++;
        switch (ch) {
        case '_':
            // disallow '__'
            if (s[0] == '_') return -1; 
            continue; 			// skip _ 
        default:
            break;
        }
        *p++ = ch;
    }
    if (*s || p == q) return -1;

    // last char cannot be '_'
    if (s[-1] == '_') return -1;
    
    // cap with NUL */
    *p = 0;

    // Run strtoll on buf to get the integer
    var endp: *u8 = undefined;
    errno = 0;
    *ret = strtoll(buf, &endp, base);
    return (errno || *endp) ? -1 : 0;
}
