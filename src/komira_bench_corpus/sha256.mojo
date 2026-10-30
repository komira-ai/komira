# SHA-256 (FIPS 180-4) of a text, as lowercase hex.
#
# The corpus hashes its own text, so the package carries the digest rather than
# depending on a cryptography library: no native code, one file. The tests
# check it against the published vectors and against komira_crypto.

comptime _HEX = "0123456789abcdef"


def _round_constants() -> List[UInt32]:
    var k: List[UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
        0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
        0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
        0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
        0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
        0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]
    return k^


def _initial_state() -> List[UInt32]:
    var h: List[UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    return h^


def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (UInt32(32) - n))


def _compress(
    mut state: List[UInt32],
    data: List[UInt8],
    base: Int,
    k: List[UInt32],
):
    """Fold the 64-byte block of `data` at `base` into `state`."""
    var w = List[UInt32]()
    for t in range(16):
        var o = base + 4 * t
        w.append(
            (UInt32(data[o]) << UInt32(24))
            | (UInt32(data[o + 1]) << UInt32(16))
            | (UInt32(data[o + 2]) << UInt32(8))
            | UInt32(data[o + 3])
        )
    for t in range(16, 64):
        var x = w[t - 15]
        var y = w[t - 2]
        var s0 = _rotr(x, UInt32(7)) ^ _rotr(x, UInt32(18)) ^ (x >> UInt32(3))
        var s1 = _rotr(y, UInt32(17)) ^ _rotr(y, UInt32(19)) ^ (y >> UInt32(10))
        w.append(w[t - 16] + s0 + w[t - 7] + s1)

    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]
    for t in range(64):
        var big1 = _rotr(e, UInt32(6)) ^ _rotr(e, UInt32(11)) ^ _rotr(
            e, UInt32(25)
        )
        var choose = (e & f) ^ (~e & g)
        var t1 = h + big1 + choose + k[t] + w[t]
        var big0 = _rotr(a, UInt32(2)) ^ _rotr(a, UInt32(13)) ^ _rotr(
            a, UInt32(22)
        )
        var majority = (a & b) ^ (a & c) ^ (b & c)
        var t2 = big0 + majority
        h = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
    state[0] = state[0] + a
    state[1] = state[1] + b
    state[2] = state[2] + c
    state[3] = state[3] + d
    state[4] = state[4] + e
    state[5] = state[5] + f
    state[6] = state[6] + g
    state[7] = state[7] + h


def sha256_hex(text: String) -> String:
    """The SHA-256 digest of the UTF-8 bytes of `text`, as 64 lowercase hex
    digits. The empty text hashes to `e3b0c442...b855`."""
    var data = List[UInt8]()
    data.extend(text.as_bytes())
    var bit_length = UInt64(len(data)) * UInt64(8)
    data.append(UInt8(0x80))
    while len(data) % 64 != 56:
        data.append(UInt8(0))
    for i in range(8):
        var shift = UInt64(56 - 8 * i)
        data.append(UInt8((bit_length >> shift) & UInt64(0xFF)))

    var k = _round_constants()
    var state = _initial_state()
    var base = 0
    while base < len(data):
        _compress(state, data, base, k)
        base += 64

    var hex_text = String(_HEX)
    var digits = hex_text.as_bytes()
    var out = List[UInt8]()
    for i in range(8):
        var word = state[i]
        for j in range(8):
            var nibble = (word >> UInt32(28 - 4 * j)) & UInt32(0xF)
            out.append(digits[Int(nibble)])
    return String(unsafe_from_utf8=Span(out))
