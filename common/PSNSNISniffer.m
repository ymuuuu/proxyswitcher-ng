#import "PSNSNISniffer.h"

// Cursor over the buffer: one bounds check before every read, so a truncated
// or hostile ClientHello yields nil instead of an out-of-bounds read.
typedef struct { const uint8_t *b; size_t len; size_t off; } PSNCur;

static BOOL curNeed(PSNCur *c, size_t n) { return c->off + n <= c->len; }

static BOOL curU8(PSNCur *c, uint8_t *out) {
    if (!curNeed(c, 1)) { return NO; }
    *out = c->b[c->off++];
    return YES;
}

static BOOL curU16(PSNCur *c, uint16_t *out) {
    if (!curNeed(c, 2)) { return NO; }
    *out = (uint16_t)((c->b[c->off] << 8) | c->b[c->off + 1]);
    c->off += 2;
    return YES;
}

static BOOL curSkip(PSNCur *c, size_t n) {
    if (!curNeed(c, n)) { return NO; }
    c->off += n;
    return YES;
}

// Both sniffed names are handed to the relay, which pastes them into an
// upstream "CONNECT <host>:<port> HTTP/1.1\r\n" request line. A name is
// attacker-controlled data from the first bytes a client sent us, so restrict
// it to the DNS hostname alphabet here rather than trusting it downstream: a
// CR or LF would let a crafted ClientHello inject arbitrary extra headers into
// that request, and a space would corrupt the request line. Underscore is
// allowed because it appears in real hostnames and is harmless in this context.
// A rejected name is not fatal - the caller falls back to the destination IP.
static BOOL PSNIsPlausibleHostname(const uint8_t *b, size_t n) {
    if (n == 0 || n > 253) { return NO; }
    for (size_t i = 0; i < n; i++) {
        uint8_t ch = b[i];
        BOOL legal = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                     (ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '_';
        if (!legal) { return NO; }
    }
    return YES;
}

NSString *PSNSniffTLSServerName(const uint8_t *buf, size_t len) {
    if (!buf || len < 5) { return nil; }
    PSNCur c = { buf, len, 0 };
    uint8_t u8; uint16_t u16;

    // Record header: content type, version, length.
    if (!curU8(&c, &u8) || u8 != 0x16) { return nil; }   // handshake records only
    if (!curSkip(&c, 2)) { return nil; }                 // record version
    if (!curU16(&c, &u16)) { return nil; }
    // Clamp to what we actually hold; the first record carries the extensions.
    if (c.off + u16 < c.len) { c.len = c.off + u16; }

    // Handshake header: must be ClientHello.
    if (!curU8(&c, &u8) || u8 != 0x01) { return nil; }
    if (!curSkip(&c, 3 + 2 + 32)) { return nil; }        // hs len, version, random

    // session id
    if (!curU8(&c, &u8)) { return nil; }
    if (!curSkip(&c, u8)) { return nil; }
    // cipher suites
    if (!curU16(&c, &u16)) { return nil; }
    if (!curSkip(&c, u16)) { return nil; }
    // compression methods
    if (!curU8(&c, &u8)) { return nil; }
    if (!curSkip(&c, u8)) { return nil; }
    // extensions block
    if (!curU16(&c, &u16)) { return nil; }
    if (c.off + u16 < c.len) { c.len = c.off + u16; }    // clamp to extensions

    while (c.off < c.len) {
        uint16_t extType, extLen;
        if (!curU16(&c, &extType) || !curU16(&c, &extLen)) { return nil; }
        if (extType != 0x0000) {                          // not server_name
            if (!curSkip(&c, extLen)) { return nil; }
            continue;
        }
        // server_name extension: list len, name type, name len, name.
        if (!curU16(&c, &u16)) { return nil; }            // list length
        if (!curU8(&c, &u8) || u8 != 0x00) { return nil; }// only host_name is defined
        uint16_t nameLen;
        if (!curU16(&c, &nameLen)) { return nil; }
        if (nameLen == 0 || !curNeed(&c, nameLen)) { return nil; }
        if (!PSNIsPlausibleHostname(c.b + c.off, nameLen)) { return nil; }
        return [[NSString alloc] initWithBytes:(c.b + c.off)
                                        length:nameLen
                                      encoding:NSUTF8StringEncoding];
    }
    return nil;
}

// "[2001:db8::1]" - brackets included, hex/colon/dot inside. Same reasoning as
// PSNIsPlausibleHostname: this reaches an upstream request line.
static BOOL PSNIsBracketedIPv6Literal(NSString *value) {
    if (value.length < 4 || ![value hasPrefix:@"["] || ![value hasSuffix:@"]"]) { return NO; }
    NSString *inner = [value substringWithRange:NSMakeRange(1, value.length - 2)];
    NSCharacterSet *illegal = [[NSCharacterSet characterSetWithCharactersInString:
                               @"0123456789abcdefABCDEF:."] invertedSet];
    return [inner rangeOfCharacterFromSet:illegal].location == NSNotFound;
}

BOOL PSNHostnameIsRequestLineSafe(NSString *host) {
    if (host.length == 0) { return NO; }
    if ([host hasPrefix:@"["]) { return PSNIsBracketedIPv6Literal(host); }
    const char *raw = host.UTF8String;
    return raw && PSNIsPlausibleHostname((const uint8_t *)raw, strlen(raw));
}

NSString *PSNSniffHTTPHost(const uint8_t *buf, size_t len) {
    if (!buf || len == 0) { return nil; }

    // The head is ASCII by definition; non-ASCII bytes just fail to match.
    NSString *head = [[NSString alloc] initWithBytes:buf
                                              length:len
                                            encoding:NSASCIIStringEncoding];
    if (head.length == 0) { return nil; }

    // Scan lines manually so a head not yet terminated by CRLFCRLF still works
    // (we peek only the first packet, which may be a partial head).
    NSRange search = NSMakeRange(0, head.length);
    while (search.location < head.length) {
        NSRange eol = [head rangeOfString:@"\r\n" options:0 range:search];
        NSRange line = (eol.location == NSNotFound)
            ? NSMakeRange(search.location, head.length - search.location)
            : NSMakeRange(search.location, eol.location - search.location);

        NSString *rawLine = [head substringWithRange:line];
        NSRange colon = [rawLine rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *name = [rawLine substringToIndex:colon.location];
            if ([name caseInsensitiveCompare:@"Host"] == NSOrderedSame) {
                NSString *value = [[rawLine substringFromIndex:colon.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([value hasPrefix:@"["]) {
                    // Bracketed IPv6 literal. The port, when present, follows
                    // the closing bracket - splitting on the last colon would
                    // cut the address itself. Brackets are kept: that is the
                    // form a CONNECT target needs.
                    NSRange close = [value rangeOfString:@"]"];
                    if (close.location == NSNotFound) { return nil; }
                    value = [value substringToIndex:close.location + 1];
                    return PSNIsBracketedIPv6Literal(value) ? value : nil;
                }
                NSRange pc = [value rangeOfString:@":" options:NSBackwardsSearch];
                if (pc.location != NSNotFound) {
                    value = [value substringToIndex:pc.location];   // strip ":port"
                }
                const char *raw = value.UTF8String;
                if (!raw || !PSNIsPlausibleHostname((const uint8_t *)raw, strlen(raw))) {
                    return nil;
                }
                return value;
            }
        }
        if (eol.location == NSNotFound) { break; }
        search.location = eol.location + 2;
        search.length = head.length - search.location;
    }
    return nil;
}
