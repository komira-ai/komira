# =============================================================================
# DIGEST — column-level kernels for `md5(s)` / `sha1(s)` / `sha256(s)`.
# =============================================================================
#
# Three `STRFN_*` members whose output is the
# LOWERCASE HEX digest of the argument's UTF-8 BYTES, as a Utf8 column.
#
# ⭐ WHY THESE ARE HERE AND NOT `komira_crypto`, WHICH ALREADY HAS A `sha256`.
# Two independent reasons, and the second is the load-bearing one:
#
#   1. `komira_crypto.sha256` IS NOT A MOJO KERNEL — it is a thin wrapper over
#      AWS-LC's `SHA256()` symbol through `internal.asm.sha256_ffi`. Reaching
#      it from the evaluator would put a linked native library on the engine's
#      column-eval path for a scalar SQL function, and MD5 and SHA-1 are not
#      there at all, so two of the three would have to be written regardless.
#   2. ⛔ `komira_compiler -> komira_crypto` WOULD WELD THE CRYPTO TEST SUITE
#      ONTO EVERY BUILD OF THE ENGINE. A library's declared tests gate its
#      build artifact and EVERY CONSUMER INHERITS THEM TRANSITIVELY, and
#      `komira_crypto` declares the CAVP SHA-256/384/512 long/monte/short
#      suites, the AES-GCM KATs and more; a digest kernel is not a reason to
#      make the whole engine wait on the certificate suite.
#
# ⇒ These are self-contained pure-Mojo implementations in the layer that uses
#   them. The duplication is deliberate and is DECLARED here so the next reader
#   does not "fix" it by adding the edge.
#
# ⭐ AND THE ORACLE FOR THEM IS NOT DuckDB. MD5, SHA-1 and SHA-256 have FIXED
# PUBLISHED TEST VECTORS (RFC 1321 §A.5, RFC 3174, FIPS 180-2 §B), so these
# kernels are pinned to a standard rather than to the parity target's build.
# The vectors were nevertheless RE-MEASURED through DuckDB v1.5.3 over a COLUMN
# and agree byte for byte:
#     md5('abc')    = 900150983cd24fb0d6963f7d28e17f72
#     sha1('abc')   = a9993e364706816aba3e25717850c26c9cd0d89d
#     sha256('abc') = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
#
# ⛔ THE DIGEST IS OVER UTF-8 BYTES, NOT CODEPOINTS, AND THE WITNESS IS `é`.
# DuckDB v1.5.3: `md5('é')` = 66ddcd97cfdeabb2f6fb8a999b4bc76f, which is the
# digest of the TWO bytes C3 A9 — not of the codepoint U+00E9. A kernel that
# iterated codepoints would agree with DuckDB on every ASCII fixture and
# diverge on the first accented character (the `chr`-as-a-codepoint-
# constructor trap).
#
# ⛔ LOWERCASE HEX. DuckDB returns `900150983cd24fb0...`, lowercase,
# for all three — unlike `hex(s)` / `to_hex(s)` on this same engine, which are
# UPPERCASE. The two live one screen apart in the eval ladder and share nothing
# but a name, so `_hex_digit_upper` is deliberately NOT reused here.
#
# NULL: a NULL input row yields a NULL output row. The caller (the
# `EXPR_STRING_FN` arm) carries the input validity bitmap through for the whole
# family, so these kernels never see a null and never construct one.
#
# Encapsulation: no `UnsafePointer` in any signature
# here, no wildcard origins, no `unsafe_from_address`.
# =============================================================================


@always_inline
def _hex_digit_lower(v: Int) -> UInt8:
    """One LOWERCASE hex ASCII digit for a nibble `v` in 0..15.

    ⛔ LOWERCASE, AND THAT IS MEASURED RATHER THAN CONVENTIONAL. `hex(s)` on
    this same engine is UPPERCASE (`hex('abc')` = '616263' is digit-only and
    hides it; `hex('é')` = 'C3A9' shows it). DuckDB's digest functions are
    lowercase. Sharing one helper between the two families would make one of
    them wrong in a way no ASCII-digit fixture can see."""
    if v < 10:
        return UInt8(48 + v)  # '0'..'9'
    return UInt8(87 + v)  # 'a'..'f'  (97 + v - 10)


@always_inline
def _rotl32(x: UInt32, n: Int) -> UInt32:
    """Rotate a 32-bit word LEFT by `n`, with `n` in 1..31.

    ⚠ `n` IS NEVER 0 OR 32 IN THIS FILE and the shape below relies on it: a
    shift of 32 on a 32-bit word is not a defined rotation here. The three
    algorithms' shift tables are 1..31 by construction (MD5 4..23, SHA-1
    {1,5,30}, SHA-256 reads rotr with 2..25), so the guard is the CALLER's
    and is stated rather than branched on."""
    return (x << UInt32(n)) | (x >> UInt32(32 - n))


@always_inline
def _rotr32(x: UInt32, n: Int) -> UInt32:
    """Rotate a 32-bit word RIGHT by `n`, with `n` in 1..31."""
    return (x >> UInt32(n)) | (x << UInt32(32 - n))


def _hex_lower_bytes_be(words: List[UInt32]) -> List[UInt8]:
    """Render `words` BIG-ENDIAN as lowercase hex ASCII — the SHA output rule.

    SHA-1 and SHA-256 both serialise their state words most-significant byte
    first. MD5 does the OPPOSITE and has its own renderer below; the pair is
    split precisely so neither can be reached by the wrong algorithm."""
    var out = List[UInt8](capacity=8 * len(words))
    for i in range(len(words)):
        var w = words[i]
        for shift in range(28, -4, -4):
            out.append(_hex_digit_lower(Int((w >> UInt32(shift)) & 0xF)))
    return out^


def _hex_lower_bytes_le(words: List[UInt32]) -> List[UInt8]:
    """Render `words` LITTLE-ENDIAN as lowercase hex ASCII — the MD5 rule.

    ⛔ MD5 SERIALISES ITS STATE LITTLE-ENDIAN AND THE SHA FAMILY DOES NOT.
    Rendering MD5 big-endian produces a well-formed 32-character hex string of
    the right length whose every byte pair is in the wrong place — a wrong
    answer that looks exactly like a right one. `md5('abc')` is
    `900150983cd24fb0d6963f7d28e17f72`; the big-endian rendering of the same
    state is `9801509063cd24fb0d6963f7d28e17f72`-shaped and is not it."""
    var out = List[UInt8](capacity=8 * len(words))
    for i in range(len(words)):
        var w = words[i]
        for b in range(4):
            var byte = Int((w >> UInt32(8 * b)) & 0xFF)
            out.append(_hex_digit_lower((byte >> 4) & 0xF))
            out.append(_hex_digit_lower(byte & 0xF))
    return out^


def _padded_length(n: Int) -> Int:
    """Total padded byte length for a message of `n` bytes.

    Both padding schemes here are identical in SHAPE — one 0x80 byte, zeros up
    to 56 mod 64, then an 8-byte bit length — and differ ONLY in the byte order
    of that length. So the length arithmetic is shared and the two writers are
    not."""
    return ((n + 8) // 64 + 1) * 64


# =============================================================================
# MD5 — RFC 1321.
# =============================================================================

comptime _MD5_K: SIMD[DType.uint32, 64] = SIMD[DType.uint32, 64](
    0xD76AA478, 0xE8C7B756, 0x242070DB, 0xC1BDCEEE,
    0xF57C0FAF, 0x4787C62A, 0xA8304613, 0xFD469501,
    0x698098D8, 0x8B44F7AF, 0xFFFF5BB1, 0x895CD7BE,
    0x6B901122, 0xFD987193, 0xA679438E, 0x49B40821,
    0xF61E2562, 0xC040B340, 0x265E5A51, 0xE9B6C7AA,
    0xD62F105D, 0x02441453, 0xD8A1E681, 0xE7D3FBC8,
    0x21E1CDE6, 0xC33707D6, 0xF4D50D87, 0x455A14ED,
    0xA9E3E905, 0xFCEFA3F8, 0x676F02D9, 0x8D2A4C8A,
    0xFFFA3942, 0x8771F681, 0x6D9D6122, 0xFDE5380C,
    0xA4BEEA44, 0x4BDECFA9, 0xF6BB4B60, 0xBEBFBC70,
    0x289B7EC6, 0xEAA127FA, 0xD4EF3085, 0x04881D05,
    0xD9D4D039, 0xE6DB99E5, 0x1FA27CF8, 0xC4AC5665,
    0xF4292244, 0x432AFF97, 0xAB9423A7, 0xFC93A039,
    0x655B59C3, 0x8F0CCC92, 0xFFEFF47D, 0x85845DD1,
    0x6FA87E4F, 0xFE2CE6E0, 0xA3014314, 0x4E0811A1,
    0xF7537E82, 0xBD3AF235, 0x2AD7D2BB, 0xEB86D391,
)
"""`floor(2**32 * abs(sin(i + 1)))` for i in 0..63 — RFC 1321's T table."""

comptime _MD5_SHIFT_DOC: Int = 0
"""⛔ THERE IS NO MD5 SHIFT TABLE, AND ITS ABSENCE IS DELIBERATE. The 64
rotation amounts are written as a comptime ternary inside each of the four
unrolled phases (`7/12/17/22`, `5/9/14/20`, `4/11/16/23`, `6/10/15/21`, cycling
on `i % 4`), so each becomes a CONSTANT shift in the emitted code.

⚠ A TABLE HERE DOES NOT COMPILE, WHICH IS WHY. A `comptime InlineArray`
subscripted from a function body — with a comptime index too — makes the
compiler materialize the whole array into the runtime frame, and `InlineArray`
is not `ImplicitlyCopyable`, so it REFUSES ("cannot materialize comptime value
of type 'Array[Int, Int(64)]'"). `_MD5_K` and `_SHA256_K` solve the same
problem the other way, as `SIMD` — which IS `ImplicitlyCopyable` — because
their 64 values follow no pattern a ternary could express. The shifts do."""



def md5_hex_bytes(s: String) -> List[UInt8]:
    """`md5(s)` — RFC 1321, over the UTF-8 BYTES of `s`, LOWERCASE hex.

    MEASURED against DuckDB v1.5.3 over a COLUMN (not a folded literal):
      * `md5('abc')` = '900150983cd24fb0d6963f7d28e17f72'  (RFC 1321 §A.5)
      * `md5('')`    = 'd41d8cd98f00b204e9800998ecf8427e'
      * `md5('a')`   = '0cc175b9c0f1b6a831c399e269772661'
      * `md5('The quick brown fox jumps over the lazy dog')`
                     = '9e107d9d372bb6826bd81d3542a419d6'
      * `md5('é')`   = '66ddcd97cfdeabb2f6fb8a999b4bc76f'  — TWO bytes, C3 A9
      * `md5('😀')`  = '2a02eac39d716a70ecf37579185927b6'  — FOUR bytes

    ⛔ THE MESSAGE LENGTH IS APPENDED LITTLE-ENDIAN AND THE STATE IS RENDERED
    LITTLE-ENDIAN. SHA-1 and SHA-256 in this same file do both BIG-endian. A
    32-character hex string comes out either way."""
    var b = s.as_bytes()
    var n = len(b)
    var total = _padded_length(n)

    var msg = List[UInt8](capacity=total)
    for i in range(n):
        msg.append(b[i])
    msg.append(0x80)
    while len(msg) < total - 8:
        msg.append(0)
    # ⚠ LITTLE-ENDIAN 64-bit BIT length — bytes, times eight.
    var bitlen = UInt64(n) * 8
    for k in range(8):
        msg.append(UInt8((bitlen >> UInt64(8 * k)) & 0xFF))

    var h0 = UInt32(0x67452301)
    var h1 = UInt32(0xEFCDAB89)
    var h2 = UInt32(0x98BADCFE)
    var h3 = UInt32(0x10325476)

    var chunk = 0
    while chunk < total:
        # 16 LITTLE-ENDIAN 32-bit words.
        var m = List[UInt32](capacity=16)
        for w in range(16):
            var o = chunk + 4 * w
            m.append(
                UInt32(msg[o])
                | (UInt32(msg[o + 1]) << 8)
                | (UInt32(msg[o + 2]) << 16)
                | (UInt32(msg[o + 3]) << 24)
            )

        var a = h0
        var bb = h1
        var c = h2
        var d = h3

        # ⛔ FOUR `comptime for` PHASES, NOT ONE RUNTIME LOOP WITH A BRANCH.
        # The branch is on a comptime value in every phase, so unrolling costs
        # nothing and removes it.
        #
        # ⚠ AND `_MD5_K` IS A `SIMD`, NOT AN `InlineArray`, WHICH IS THE PART
        # THAT IS FORCED. A `comptime InlineArray` subscripted from a function
        # body makes the compiler materialize the whole array into the runtime
        # frame, and `InlineArray` is not `ImplicitlyCopyable`, so it REFUSES:
        # "cannot materialize comptime value of type 'Array[UInt32, Int(64)]'".
        #
        # ⛔ AND UNROLLING DOES NOT FIX THAT. A COMPTIME index into a
        # `comptime InlineArray`
        # materializes it just the same; the refusal is about the array's
        # type, not about when the index is known. `SIMD` IS
        # `ImplicitlyCopyable`, so it is indexable from either world, and the
        # shift amounts avoid the question entirely by being a comptime
        # ternary rather than a table (see `_MD5_SHIFT_DOC`).
        comptime for i in range(16):
            comptime sh = (
                7 if i % 4 == 0 else 12 if i % 4 == 1 else 17 if i % 4 == 2
                else 22
            )
            var f = (bb & c) | (~bb & d)
            var tmp = d
            d = c
            c = bb
            bb = bb + _rotl32(a + f + _MD5_K[i] + m[i], sh)
            a = tmp
        comptime for i in range(16, 32):
            var f = (d & bb) | (~d & c)
            var tmp = d
            d = c
            c = bb
            comptime sh = (
                5 if i % 4 == 0 else 9 if i % 4 == 1 else 14 if i % 4 == 2
                else 20
            )
            bb = bb + _rotl32(
                a + f + _MD5_K[i] + m[(5 * i + 1) % 16], sh
            )
            a = tmp
        comptime for i in range(32, 48):
            var f = bb ^ c ^ d
            var tmp = d
            d = c
            c = bb
            comptime sh = (
                4 if i % 4 == 0 else 11 if i % 4 == 1 else 16 if i % 4 == 2
                else 23
            )
            bb = bb + _rotl32(
                a + f + _MD5_K[i] + m[(3 * i + 5) % 16], sh
            )
            a = tmp
        comptime for i in range(48, 64):
            var f = c ^ (bb | ~d)
            var tmp = d
            d = c
            c = bb
            comptime sh = (
                6 if i % 4 == 0 else 10 if i % 4 == 1 else 15 if i % 4 == 2
                else 21
            )
            bb = bb + _rotl32(
                a + f + _MD5_K[i] + m[(7 * i) % 16], sh
            )
            a = tmp

        h0 = h0 + a
        h1 = h1 + bb
        h2 = h2 + c
        h3 = h3 + d
        chunk += 64

    var state = List[UInt32](capacity=4)
    state.append(h0)
    state.append(h1)
    state.append(h2)
    state.append(h3)
    return _hex_lower_bytes_le(state)


# =============================================================================
# SHA-1 — RFC 3174.
# =============================================================================


def sha1_hex_bytes(s: String) -> List[UInt8]:
    """`sha1(s)` — RFC 3174, over the UTF-8 BYTES of `s`, LOWERCASE hex.

    MEASURED against DuckDB v1.5.3 over a COLUMN:
      * `sha1('abc')` = 'a9993e364706816aba3e25717850c26c9cd0d89d'  (RFC 3174)
      * `sha1('')`    = 'da39a3ee5e6b4b0d3255bfef95601890afd80709'
      * `sha1('a')`   = '86f7e437faa5a7fce15d1ddcb9eaeaea377667b8'
      * `sha1('The quick brown fox jumps over the lazy dog')`
                      = '2fd4e1c67a2d28fced849ee1bb76e7391b93eb12'
      * `sha1('é')`   = 'bf15be717ac1b080b4f1c456692825891ff5073d'

    ⚠ 160 BITS = 40 HEX CHARACTERS, not 32. The three digests in this file have
    three different output widths (32 / 40 / 64), which is the cheapest
    assertion that an eval arm dispatched to the op it was asked for."""
    var b = s.as_bytes()
    var n = len(b)
    var total = _padded_length(n)

    var msg = List[UInt8](capacity=total)
    for i in range(n):
        msg.append(b[i])
    msg.append(0x80)
    while len(msg) < total - 8:
        msg.append(0)
    # ⚠ BIG-ENDIAN 64-bit BIT length.
    var bitlen = UInt64(n) * 8
    for k in range(7, -1, -1):
        msg.append(UInt8((bitlen >> UInt64(8 * k)) & 0xFF))

    var h0 = UInt32(0x67452301)
    var h1 = UInt32(0xEFCDAB89)
    var h2 = UInt32(0x98BADCFE)
    var h3 = UInt32(0x10325476)
    var h4 = UInt32(0xC3D2E1F0)

    var chunk = 0
    while chunk < total:
        var w = List[UInt32](capacity=80)
        for i in range(16):
            var o = chunk + 4 * i
            w.append(
                (UInt32(msg[o]) << 24)
                | (UInt32(msg[o + 1]) << 16)
                | (UInt32(msg[o + 2]) << 8)
                | UInt32(msg[o + 3])
            )
        for i in range(16, 80):
            w.append(_rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1))

        var a = h0
        var bb = h1
        var c = h2
        var d = h3
        var e = h4

        # Four comptime phases — same reasoning as MD5 above, except that
        # SHA-1's constants are four literals rather than a table, so the
        # unroll here buys the branch removal only.
        comptime for i in range(20):
            var f = (bb & c) | (~bb & d)
            var temp = _rotl32(a, 5) + f + e + UInt32(0x5A827999) + w[i]
            e = d
            d = c
            c = _rotl32(bb, 30)
            bb = a
            a = temp
        comptime for i in range(20, 40):
            var f = bb ^ c ^ d
            var temp = _rotl32(a, 5) + f + e + UInt32(0x6ED9EBA1) + w[i]
            e = d
            d = c
            c = _rotl32(bb, 30)
            bb = a
            a = temp
        comptime for i in range(40, 60):
            var f = (bb & c) | (bb & d) | (c & d)
            var temp = _rotl32(a, 5) + f + e + UInt32(0x8F1BBCDC) + w[i]
            e = d
            d = c
            c = _rotl32(bb, 30)
            bb = a
            a = temp
        comptime for i in range(60, 80):
            var f = bb ^ c ^ d
            var temp = _rotl32(a, 5) + f + e + UInt32(0xCA62C1D6) + w[i]
            e = d
            d = c
            c = _rotl32(bb, 30)
            bb = a
            a = temp

        h0 = h0 + a
        h1 = h1 + bb
        h2 = h2 + c
        h3 = h3 + d
        h4 = h4 + e
        chunk += 64

    var state = List[UInt32](capacity=5)
    state.append(h0)
    state.append(h1)
    state.append(h2)
    state.append(h3)
    state.append(h4)
    return _hex_lower_bytes_be(state)


# =============================================================================
# SHA-256 — FIPS 180-2.
# =============================================================================

comptime _SHA256_K: SIMD[DType.uint32, 64] = SIMD[DType.uint32, 64](
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
)
"""First 32 bits of the fractional parts of the cube roots of the first 64
primes — FIPS 180-2 §4.2.2."""


def sha256_hex_bytes(s: String) -> List[UInt8]:
    """`sha256(s)` — FIPS 180-2, over the UTF-8 BYTES of `s`, LOWERCASE hex.

    MEASURED against DuckDB v1.5.3 over a COLUMN:
      * `sha256('abc')` =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        (FIPS 180-2 §B.1)
      * `sha256('')` =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      * `sha256('a')` =
        'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb'
      * `sha256('é')` =
        '4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c'

    ⭐ THIS IS A SECOND SHA-256 AND THAT IS DELIBERATE — see the file header.
    `komira_crypto.sha256` is an AWS-LC FFI wrapper whose package declares a
    large gating test suite; reaching it from the evaluator would put both a
    native library and that whole suite on every engine build."""
    var b = s.as_bytes()
    var n = len(b)
    var total = _padded_length(n)

    var msg = List[UInt8](capacity=total)
    for i in range(n):
        msg.append(b[i])
    msg.append(0x80)
    while len(msg) < total - 8:
        msg.append(0)
    var bitlen = UInt64(n) * 8
    for k in range(7, -1, -1):
        msg.append(UInt8((bitlen >> UInt64(8 * k)) & 0xFF))

    var h0 = UInt32(0x6A09E667)
    var h1 = UInt32(0xBB67AE85)
    var h2 = UInt32(0x3C6EF372)
    var h3 = UInt32(0xA54FF53A)
    var h4 = UInt32(0x510E527F)
    var h5 = UInt32(0x9B05688C)
    var h6 = UInt32(0x1F83D9AB)
    var h7 = UInt32(0x5BE0CD19)

    var chunk = 0
    while chunk < total:
        var w = List[UInt32](capacity=64)
        for i in range(16):
            var o = chunk + 4 * i
            w.append(
                (UInt32(msg[o]) << 24)
                | (UInt32(msg[o + 1]) << 16)
                | (UInt32(msg[o + 2]) << 8)
                | UInt32(msg[o + 3])
            )
        for i in range(16, 64):
            var v15 = w[i - 15]
            var v2 = w[i - 2]
            var s0 = _rotr32(v15, 7) ^ _rotr32(v15, 18) ^ (v15 >> 3)
            var s1 = _rotr32(v2, 17) ^ _rotr32(v2, 19) ^ (v2 >> 10)
            w.append(w[i - 16] + s0 + w[i - 7] + s1)

        var a = h0
        var bb = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var h = h7

        # ⛔ `comptime for` for `_SHA256_K[i]` — see the MD5 note. This one
        # has no conditional in it at all, so it is a single unrolled loop.
        comptime for i in range(64):
            var big_s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25)
            var ch = (e & f) ^ (~e & g)
            var temp1 = h + big_s1 + ch + _SHA256_K[i] + w[i]
            var big_s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22)
            var maj = (a & bb) ^ (a & c) ^ (bb & c)
            var temp2 = big_s0 + maj
            h = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = bb
            bb = a
            a = temp1 + temp2

        h0 = h0 + a
        h1 = h1 + bb
        h2 = h2 + c
        h3 = h3 + d
        h4 = h4 + e
        h5 = h5 + f
        h6 = h6 + g
        h7 = h7 + h
        chunk += 64

    var state = List[UInt32](capacity=8)
    state.append(h0)
    state.append(h1)
    state.append(h2)
    state.append(h3)
    state.append(h4)
    state.append(h5)
    state.append(h6)
    state.append(h7)
    return _hex_lower_bytes_be(state)
