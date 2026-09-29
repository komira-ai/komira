"""SHA-256 (FIPS 180-4), for comparing archive members with files by digest."""

from buildtools.bytes import hex_byte


def _k() -> List[UInt32]:
    var k: List[UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
        0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
        0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
        0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
        0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
        0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]
    return k^


def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (UInt32(32) - n))


def sha256_hex(data: List[UInt8], start: Int, end: Int) -> String:
    """Lower-case hex SHA-256 of bytes [start, end) of `data`."""
    var k = _k()
    var h: List[UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    var n = end - start
    # The padded tail: the last partial block, 0x80, zeros, the bit length.
    var full = n - n % 64
    var tail = List[UInt8]()
    for i in range(start + full, end):
        tail.append(data[i])
    tail.append(UInt8(0x80))
    while len(tail) % 64 != 56:
        tail.append(UInt8(0))
    var bits = UInt64(n) * 8
    for i in range(8):
        tail.append(UInt8(Int((bits >> UInt64(56 - 8 * i)) & 0xFF)))
    var w = List[UInt32](capacity=64)
    for _ in range(64):
        w.append(UInt32(0))
    var blocks = full // 64 + len(tail) // 64
    for blk in range(blocks):
        for t in range(16):
            var v = UInt32(0)
            for j in range(4):
                var idx = blk * 64 + t * 4 + j
                var byte: UInt8
                if idx < full:
                    byte = data[start + idx]
                else:
                    byte = tail[idx - full]
                v = (v << 8) | UInt32(Int(byte))
            w[t] = v
        for t in range(16, 64):
            var s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            var s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] + s0 + w[t - 7] + s1
        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for t in range(64):
            var S1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
            var ch = (e & f) ^ ((~e) & g)
            var t1 = hh + S1 + ch + k[t] + w[t]
            var S0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var t2 = S0 + maj
            hh = g
            g = f
            f = e
            e = d + t1
            d = c
            c = b
            b = a
            a = t1 + t2
        h[0] = h[0] + a
        h[1] = h[1] + b
        h[2] = h[2] + c
        h[3] = h[3] + d
        h[4] = h[4] + e
        h[5] = h[5] + f
        h[6] = h[6] + g
        h[7] = h[7] + hh
    var out = String()
    for i in range(8):
        for j in range(4):
            out += hex_byte(Int((h[i] >> UInt32(24 - 8 * j)) & 0xFF))
    return out^
