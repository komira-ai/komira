# =============================================================================
# Snappy Mojo decoder — oracle test against the C library
# =============================================================================
#
# Proves the Mojo decoder (selected with `set_snappy_decoder`) produces
# BYTE-IDENTICAL output to the snappy C library's decoder on blobs the C
# library compressed, across a matrix that hits every Snappy tag edge case:
# long literals (>60 → multi-byte length field), overlapping copies
# (offset < length, RLE), long offsets (copy-2 up to 65535, copy-4 beyond),
# max-length-64 copies, and block-boundary (65536) crossings — plus an
# incompressible (all-literal) stream.
#
# Oracle model: the snappy C library is the reference. For each input `x`:
#   c        = snappy_compress(x)              [C library]
#   out_ref  = snappy_decompress(c)            [C_LIBRARY decoder]
#   out_mojo = snappy_decompress(c)            [MOJO decoder]
# and we assert  out_ref == out_mojo == x. We run the Mojo decoder BOTH with a
# +kSlopBytes dst (fast SIMD-overshoot paths engage — the page decoder's
# shape) AND with an exact-sized dst (scalar fallback paths engage), so both
# code paths are covered.
# =============================================================================

from komira_parquet_codec.snappy import (
    SnappyDecoder,
    kSlopBytes,
    set_snappy_decoder,
    snappy_compress,
    snappy_decoder,
    snappy_decompress,
    snappy_max_compressed_length,
    snappy_uncompressed_length,
)


def _expect_eq(got: Int, want: Int, msg: String) raises:
    if got != want:
        raise Error(
            "FAIL " + msg + ": got " + String(got) + " want " + String(want)
        )


def _filled(n: Int, b: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(b)
    return out^


# -----------------------------------------------------------------------------
# C-library compress of `data` → List[UInt8] compressed blob.
# -----------------------------------------------------------------------------
def _compress_lib(data: List[UInt8]) raises -> List[UInt8]:
    var cbuf = _filled(snappy_max_compressed_length(len(data)), 0)
    var written = snappy_compress(Span(data), Span(cbuf))
    var out = List[UInt8](capacity=written)
    for i in range(written):
        out.append(cbuf[i])
    return out^


# -----------------------------------------------------------------------------
# Decode `comp` (expecting `expected_n` decoded bytes) with either the C
# decoder or the Mojo decoder, with or without +kSlopBytes dst slop. Returns
# the bytes. Puts the default decoder back before returning.
# -----------------------------------------------------------------------------
def _decode(
    comp: List[UInt8], expected_n: Int, use_mojo: Bool, slop: Bool
) raises -> List[UInt8]:
    var dcap = expected_n + kSlopBytes if slop else expected_n
    var dbuf = _filled(dcap, 0)
    set_snappy_decoder(SnappyDecoder.MOJO if use_mojo else SnappyDecoder.C_LIBRARY)
    var written = snappy_decompress(Span(comp), Span(dbuf))
    var declared = snappy_uncompressed_length(Span(comp))
    set_snappy_decoder(SnappyDecoder.C_LIBRARY)
    _expect_eq(declared, expected_n, "declared uncompressed length")
    var out = List[UInt8](capacity=written)
    for i in range(written):
        out.append(dbuf[i])
    return out^


# -----------------------------------------------------------------------------
# Roundtrip oracle for one input: compress via the C library, decode via
# C + mojo, assert all byte-identical to the original.
# -----------------------------------------------------------------------------
def _check(name: String, data: List[UInt8]) raises:
    var n = len(data)
    var comp = _compress_lib(data)

    var out_ref = _decode(comp, n, use_mojo=False, slop=True)
    var out_mojo = _decode(comp, n, use_mojo=True, slop=True)
    var out_mojo_noslop = _decode(comp, n, use_mojo=True, slop=False)

    _expect_eq(len(out_ref), n, name + ": C length")
    _expect_eq(len(out_mojo), n, name + ": mojo(slop) length")
    _expect_eq(len(out_mojo_noslop), n, name + ": mojo(noslop) length")

    for i in range(n):
        # mojo(slop) == C == original ; mojo(noslop) == original
        _expect_eq(
            Int(out_mojo[i]), Int(out_ref[i]),
            name + ": mojo(slop) vs C byte " + String(i),
        )
        _expect_eq(
            Int(out_mojo[i]), Int(data[i]),
            name + ": mojo(slop) vs original byte " + String(i),
        )
        _expect_eq(
            Int(out_mojo_noslop[i]), Int(data[i]),
            name + ": mojo(noslop) vs original byte " + String(i),
        )
    print("  PASS", name, "(", n, "bytes ->", len(comp), "compressed )")


# -----------------------------------------------------------------------------
# Deterministic byte generators.
# -----------------------------------------------------------------------------
def _lcg_bytes(n: Int, seed: UInt64) -> List[UInt8]:
    """Incompressible pseudo-random bytes (an all-literal stream)."""
    var out = List[UInt8]()
    var s = seed
    for _ in range(n):
        s = s * 6364136223846793005 + 1442695040888963407
        out.append(UInt8((s >> 33) & 0xFF))
    return out^


def _repeat_unit(unit: List[UInt8], times: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(times):
        for i in range(len(unit)):
            out.append(unit[i])
    return out^


def _const(n: Int, b: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(b)
    return out^


def main() raises:
    print("=== snappy Mojo decoder — C library oracle matrix ===")
    if snappy_decoder() != SnappyDecoder.C_LIBRARY:
        raise Error("FAIL: the default decoder is not the C library's")

    # --- tiny / boundary sizes ---
    _check("empty", List[UInt8]())
    _check("one_byte", _const(1, 0x41))
    _check("two_bytes", [UInt8(0x41), UInt8(0x42)])

    # --- RLE / overlapping copies (offset < length) ---
    _check("const_zeros_1000", _const(1000, 0))          # offset 1, long runs
    _check("const_ff_65", _const(65, 0xFF))              # copy length crosses 64
    _check("offset2_ababab", _repeat_unit([UInt8(0x61), UInt8(0x62)], 500))
    _check(
        "offset3_abcabc",
        _repeat_unit([UInt8(0x61), UInt8(0x62), UInt8(0x63)], 400),
    )
    _check(
        "offset5",
        _repeat_unit([UInt8(1), UInt8(2), UInt8(3), UInt8(4), UInt8(5)], 400),
    )
    _check(
        "offset7",
        _repeat_unit(
            [UInt8(1), UInt8(2), UInt8(3), UInt8(4), UInt8(5), UInt8(6), UInt8(7)],
            300,
        ),
    )
    _check("offset15", _repeat_unit(_lcg_bytes(15, 99), 300))
    _check("offset16", _repeat_unit(_lcg_bytes(16, 100), 300))
    _check("offset17", _repeat_unit(_lcg_bytes(17, 101), 300))

    # --- long literals (>60 → multi-byte length field) ---
    _check("literal_61", _lcg_bytes(61, 7))
    _check("literal_100", _lcg_bytes(100, 8))
    _check("literal_300", _lcg_bytes(300, 9))            # 2-byte length field
    _check("literal_70000", _lcg_bytes(70000, 10))       # 3-byte len + block xing

    # --- incompressible (all literals, various sizes) ---
    _check("rand_4096", _lcg_bytes(4096, 1))
    _check("rand_65535", _lcg_bytes(65535, 2))
    _check("rand_65536", _lcg_bytes(65536, 3))           # exactly kBlockSize
    _check("rand_131072", _lcg_bytes(131072, 4))         # 2 blocks

    # --- long offsets: big unique prefix then a repeat of an early slice
    #     (forces copy-2 with offset in [2048..65535] and copy-4 beyond 65535) ---
    var pfx = _lcg_bytes(80000, 55)
    var mix = List[UInt8]()
    for i in range(len(pfx)):
        mix.append(pfx[i])
    # repeat bytes [1000..1512) — back-reference offset ~79000 (> 65535 → copy-4)
    for i in range(512):
        mix.append(pfx[1000 + i])
    # repeat bytes [78000..78400) — offset ~2400 (copy-2)
    for i in range(400):
        mix.append(pfx[78000 + i])
    _check("long_offset_mix", mix)

    # --- text-like: a 45-byte unit repeated (mixed literals + copies,
    #     offset-45 back-references) ---
    var sentence = _lcg_bytes(45, 12345)
    _check("text_repeat", _repeat_unit(sentence, 400))

    # --- mixed: random block + constant block + random block ---
    var mixed = List[UInt8]()
    var a = _lcg_bytes(3000, 21)
    var b = _const(5000, 0x7E)
    var cc = _lcg_bytes(2000, 22)
    for i in range(len(a)):
        mixed.append(a[i])
    for i in range(len(b)):
        mixed.append(b[i])
    for i in range(len(cc)):
        mixed.append(cc[i])
    _check("mixed_blocks", mixed)

    print("=== ALL ORACLE CASES PASS ===")
