# =============================================================================
# komira_crypto/tests/test_zeroize_on_drop.mojo
# =============================================================================
#
# Validates the no-elide secure-zero helpers in `komira_crypto/zeroize.mojo`:
#
#   * zeroize_inline_array[N]     — for InlineArray[UInt8, N]
#   * zeroize_inline_array_u32[N] — for InlineArray[UInt32, N]
#   * zeroize_inline_array_u64[N] — for InlineArray[UInt64, N]
#   * zeroize_list                — for List[UInt8]
#
# The canonical secure-zero is `external_call["memset_s"]` on macOS /
# `["explicit_bzero"]` on Linux. The
# `llvm.memset.inline.p0+has_side_effect=True` pattern IS ELIDED by the
# Mojo optimizer at -O3; the external_call path survives because the
# compiler cannot DCE across the FFI boundary.
#
# This file does NOT verify disasm survival under -O3 (that requires
# build-side asm emission + grep). Here we verify the FUNCTIONAL
# contract: after the helper runs, the buffer is observably zero, using
# the SAME helper whose -O3 survival the disassembly shows.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import (
    Sha256,
    zeroize_inline_array,
    zeroize_inline_array_u32,
    zeroize_inline_array_u64,
    zeroize_list,
)


# -----------------------------------------------------------------------------
# Functional contract — the helper zeroes the buffer.
# -----------------------------------------------------------------------------


def test_zeroize_uint8_basic() raises:
    """zeroize_inline_array[N] zeroes an N-byte buffer."""
    var arr = Array[UInt8, 32](fill=UInt8(0xCB))
    # Pre: every byte is 0xCB.
    for i in range(32):
        assert_equal(Int(arr[i]), 0xCB)

    zeroize_inline_array[32](arr)

    # Post: every byte is 0.
    for i in range(32):
        assert_equal(Int(arr[i]), 0)


def test_zeroize_uint8_various_sizes() raises:
    """zeroize_inline_array[N] works at multiple comptime-known sizes."""
    var a16 = Array[UInt8, 16](fill=UInt8(0xAB))
    zeroize_inline_array[16](a16)
    for i in range(16):
        assert_equal(Int(a16[i]), 0)

    var a64 = Array[UInt8, 64](fill=UInt8(0xCD))
    zeroize_inline_array[64](a64)
    for i in range(64):
        assert_equal(Int(a64[i]), 0)

    var a128 = Array[UInt8, 128](fill=UInt8(0xEF))
    zeroize_inline_array[128](a128)
    for i in range(128):
        assert_equal(Int(a128[i]), 0)


def test_zeroize_uint32_basic() raises:
    """zeroize_inline_array_u32[N] zeroes an N-word buffer (4N bytes)."""
    var state = Array[UInt32, 8](fill=UInt32(0xDEADBEEF))
    # Pre.
    for i in range(8):
        assert_equal(Int(state[i]), 0xDEADBEEF)

    zeroize_inline_array_u32[8](state)

    # Post.
    for i in range(8):
        assert_equal(Int(state[i]), 0)


def test_zeroize_uint32_sha256_state_shape() raises:
    """The Sha256 struct uses InlineArray[UInt32, 8] for its hash state.
    Verify the helper handles that exact shape."""
    var state = Array[UInt32, 8](fill=UInt32(0))
    state[0] = UInt32(0x6a09e667)
    state[1] = UInt32(0xbb67ae85)
    state[2] = UInt32(0x3c6ef372)
    state[3] = UInt32(0xa54ff53a)
    state[4] = UInt32(0x510e527f)
    state[5] = UInt32(0x9b05688c)
    state[6] = UInt32(0x1f83d9ab)
    state[7] = UInt32(0x5be0cd19)

    zeroize_inline_array_u32[8](state)

    for i in range(8):
        assert_equal(Int(state[i]), 0)


def test_zeroize_uint64_every_byte() raises:
    """zeroize_inline_array_u64[N] zeroes all 8N bytes of an N-word buffer.

    Every byte of every word is nonzero and distinct before the call, so a
    byte count short by one byte (the top byte of the last word, on a
    little-endian target) or by whole words leaves a nonzero word behind.
    """
    var state = Array[UInt64, 8](fill=UInt64(0))
    for i in range(8):
        state[i] = UInt64(0x8877665544332211) + UInt64(i)
    # Pre.
    assert_equal(state[7], UInt64(0x8877665544332218))

    zeroize_inline_array_u64[8](state)

    # Post.
    for i in range(8):
        assert_equal(state[i], UInt64(0), String("word ", i, " not zeroed"))


def test_zeroize_uint64_single_word() raises:
    """N == 1: the one word, high bit set, is cleared (8 bytes, not N)."""
    var one = Array[UInt64, 1](fill=UInt64(0xFFFFFFFFFFFFFFFF))
    zeroize_inline_array_u64[1](one)
    assert_equal(one[0], UInt64(0))


# -----------------------------------------------------------------------------
# Bounds — each helper writes its own buffer and nothing next to it. The
# buffer under test is the middle row of a 3-row nested array, so the bytes
# just before it and just after it are the neighbouring rows: a byte count
# one byte too long, or a start pointer moved off the buffer, changes a
# neighbour and the test fails.
# -----------------------------------------------------------------------------


def test_zeroize_uint8_stays_in_bounds() raises:
    """zeroize_inline_array[N] zeroes exactly its N bytes."""
    var outer = Array[Array[UInt8, 16], 3](fill=Array[UInt8, 16](fill=UInt8(0xA5)))
    zeroize_inline_array[16](outer[1])
    for i in range(16):
        assert_equal(Int(outer[1][i]), 0, String("byte ", i, " not zeroed"))
        assert_equal(Int(outer[0][i]), 0xA5, String("before byte ", i, " touched"))
        assert_equal(Int(outer[2][i]), 0xA5, String("after byte ", i, " touched"))


def test_zeroize_uint32_stays_in_bounds() raises:
    """zeroize_inline_array_u32[N] zeroes exactly its N*4 bytes."""
    var outer = Array[Array[UInt32, 4], 3](fill=Array[UInt32, 4](fill=UInt32(0xA5A5A5A5)))
    zeroize_inline_array_u32[4](outer[1])
    for i in range(4):
        assert_equal(outer[1][i], UInt32(0), String("word ", i, " not zeroed"))
        assert_equal(outer[0][i], UInt32(0xA5A5A5A5), String("before word ", i, " touched"))
        assert_equal(outer[2][i], UInt32(0xA5A5A5A5), String("after word ", i, " touched"))


def test_zeroize_uint64_stays_in_bounds() raises:
    """zeroize_inline_array_u64[N] zeroes exactly its N*8 bytes."""
    var outer = Array[Array[UInt64, 4], 3](fill=Array[UInt64, 4](fill=UInt64(0xA5A5A5A5A5A5A5A5)))
    zeroize_inline_array_u64[4](outer[1])
    for i in range(4):
        assert_equal(outer[1][i], UInt64(0), String("word ", i, " not zeroed"))
        assert_equal(outer[0][i], UInt64(0xA5A5A5A5A5A5A5A5), String("before word ", i, " touched"))
        assert_equal(outer[2][i], UInt64(0xA5A5A5A5A5A5A5A5), String("after word ", i, " touched"))


def test_zeroize_list_stays_in_bounds() raises:
    """zeroize_list zeroes len(a) bytes, not the spare capacity after them."""
    var key = List[UInt8](capacity=64)
    for _ in range(64):
        key.append(UInt8(0xA5))
    key.resize(32, UInt8(0))
    zeroize_list(key)
    for i in range(32):
        assert_equal(Int(key[i]), 0, String("byte ", i, " not zeroed"))
    # The 32 bytes after len(key) still hold 0xA5: shrinking a List keeps its
    # buffer, so the spare capacity is the memory just after the elements.
    # SAFETY: the read stays inside the 64-byte allocation, whose bytes were
    # all written above; UInt8 has no destructor, so resize left them as is.
    var spare = key.unsafe_ptr()
    for i in range(32, 64):
        assert_equal(Int(spare[i]), 0xA5, String("spare byte ", i, " touched"))


# -----------------------------------------------------------------------------
# Structural — a Sha256 is built, used and dropped (compile-and-run gate
# that its destructor IS defined and IS callable from drop).
#
# Sha256 does not call these helpers: its state lives in an AWS-LC
# context that its inner hasher's `__del__` frees (`EVP_MD_CTX_free`,
# which AWS-LC clears). This test asserts nothing about zeroing; it fails only if the
# destructor fails to compile, link or run.
# -----------------------------------------------------------------------------


def test_sha256_destructor_invocable() raises:
    """Construct + drop a Sha256 to exercise the __del__ path."""
    var h = Sha256()
    h.update("test".as_bytes())
    var dig = Array[UInt8, 32](fill=0)
    h.finalize_into(dig)
    # Falling out of scope here drops Sha256 and its inner hasher, whose
    # `__del__` frees the AWS-LC context. If the destructor is broken, this test fails at
    # compile, link, or runtime.
    assert_true(True)


def test_zeroize_list() raises:
    """zeroize_list zeroes every element of a List[UInt8] and keeps its
    length; an empty list is a no-op."""
    var key = List[UInt8](length=300, fill=UInt8(0x5A))
    zeroize_list(key)
    assert_equal(len(key), 300)
    for i in range(300):
        assert_equal(Int(key[i]), 0)
    var empty = List[UInt8]()
    zeroize_list(empty)
    assert_equal(len(empty), 0)


# -----------------------------------------------------------------------------
# main — invoke every test
# -----------------------------------------------------------------------------


def main() raises:
    test_zeroize_uint8_basic()
    test_zeroize_uint8_various_sizes()
    test_zeroize_uint32_basic()
    test_zeroize_uint32_sha256_state_shape()
    test_zeroize_uint64_every_byte()
    test_zeroize_uint64_single_word()
    test_zeroize_uint8_stays_in_bounds()
    test_zeroize_uint32_stays_in_bounds()
    test_zeroize_uint64_stays_in_bounds()
    test_sha256_destructor_invocable()
    test_zeroize_list()
    test_zeroize_list_stays_in_bounds()
    print("OK")
