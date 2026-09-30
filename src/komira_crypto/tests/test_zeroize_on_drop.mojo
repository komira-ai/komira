# =============================================================================
# komira_crypto/tests/test_zeroize_on_drop.mojo
# =============================================================================
#
# Validates the no-elide secure-zero helpers in `komira_crypto/zeroize.mojo`:
#
#   * zeroize_inline_array[N]     — for InlineArray[UInt8, N]
#   * zeroize_inline_array_u32[N] — for InlineArray[UInt32, N]
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


# -----------------------------------------------------------------------------
# Structural — Sha256 destructor invokes the helpers (compile-pass gate
# that the destructor IS defined and IS callable from drop).
#
# We cannot directly observe `__del__` ran (the buffer is unmappable
# afterward) — but if the destructor's body had a syntax / link error,
# this test would fail to compile or fail to run: the minimal
# zero-on-drop check at the test level.
# -----------------------------------------------------------------------------


def test_sha256_destructor_invocable() raises:
    """Construct + drop a Sha256 to exercise the __del__ path."""
    var h = Sha256()
    h.update("test".as_bytes())
    var dig = Array[UInt8, 32](fill=0)
    h.finalize_into(dig)
    # Falling out of scope here triggers Sha256.__del__ which calls
    # zeroize_inline_array_u32[8](self._state) + zeroize_inline_array
    # [64](self._buffer). If the destructor is broken, this test fails
    # at compile, link, or runtime.
    assert_true(True)


# -----------------------------------------------------------------------------
# main — invoke every test
# -----------------------------------------------------------------------------


def main() raises:
    test_zeroize_uint8_basic()
    test_zeroize_uint8_various_sizes()
    test_zeroize_uint32_basic()
    test_zeroize_uint32_sha256_state_shape()
    test_sha256_destructor_invocable()
    print("OK")
