# =============================================================================
# komira_crypto/zeroize.mojo — no-elide secure-zero helper
# =============================================================================
#
# Cryptographic primitives MUST zero their secret-bearing state on drop. The
# Mojo compiler is aggressive about dead-store elimination at -O3:
# when a secret buffer has no escape after its last read, the compiler is
# free to DCE both the secret-fill stores AND the destructor's memset.
# Without an explicit no-elide barrier, the secret material remains in
# stack-spilled registers / scratch memory long after the struct is
# destroyed and is recoverable by any process that allocates over the
# stack slot.
#
# This module provides ONE canonical `zeroize_inline_array[N]` helper.
# Every Sha256 / Hmac / Aead / KeySchedule conformer in `komira_crypto`
# calls into this helper from its `__del__(deinit self)`.
#
# # WHY external_call (not llvm.memset.inline.p0+has_side_effect=True)
#
# The natural spelling is `llvm.memset.inline.p0` with the
# `has_side_effect=True` flag. A probe with -O3 disassembly verification
# shows this pattern IS ELIDED by the Mojo optimizer when the target
# buffer has no escape. The `external_call` form (`memset_s` on macOS /
# `explicit_bzero` on Linux) emits a `bl _memset_s` / `bl _explicit_bzero`
# call that survives -O3 — the optimizer cannot DCE across an FFI
# boundary because it has no visibility into the callee's behavior.
#
# So:
#   * macOS: `external_call["memset_s", Int](ptr, smax, c, n)` — C11
#     Annex K bounds-checked memset; returns errno_t (discarded).
#     Available since macOS 10.9.
#   * Linux/BSD: `external_call["explicit_bzero", NoneType](ptr, n)` —
#     POSIX-extension secure-zero; void return. Available since glibc
#     2.25 / musl 1.1.20.
#
# # SAFETY discipline
#
# This file uses `UnsafePointer(to=a).bitcast[UInt8]()` INSIDE the helper
# body. This is the lowest-tier pointer use, justified by:
#   * The pointer never crosses a module boundary — it is constructed
#     and consumed in the same function body.
#   * The origin is inferred concretely from the local `a` (it is the
#     borrow-origin of `a`); no wildcard origin (`MutAnyOrigin`,
#     `MutExternalOrigin`, etc).
#   * The pointer-arithmetic is encapsulated in this ONE helper. Every
#     `__del__` call site looks like `zeroize_inline_array[N](self.x)`
#     — no raw arithmetic in conformer bodies.
#
# Encapsulation invariants:
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget


@always_inline
def zeroize_inline_array[N: Int](mut a: Array[UInt8, N]):
    """No-elide secure-zero for an `InlineArray[UInt8, N]`.

    The `llvm.memset.inline.p0+
    has_side_effect=True` pattern IS ELIDED at -O3 on Mojo 1.0.0b1.
    The only reliable path is `external_call` to libc's secure-zero
    function. The compiler cannot DCE across the FFI boundary
    because the callee's behavior is opaque at compile time.

    Per-OS dispatch:
      * macOS: `memset_s(ptr, smax, c, n)` — C11 Annex K. Returns
        errno_t (0 on success); we discard it.
      * Linux/BSD: `explicit_bzero(ptr, n)` — POSIX extension.

    # SAFETY: `UnsafePointer(to=a).bitcast[UInt8]()` constructs a
    # local pointer with origin inferred from `a` (NOT a wildcard
    # origin). The pointer never crosses this function's boundary.
    # `memset_s`/`explicit_bzero` write exactly N bytes through it
    # before returning. No aliasing concern because `mut a:
    # InlineArray[UInt8, N]` is the unique owner.
    """
    comptime if CompilationTarget.is_macos():
        # memset_s(ptr, smax, c, n) — C11 Annex K bounds-checked memset.
        # Returns errno_t (Int, 0 on success). Discard return value.
        var _e = external_call["memset_s", Int](
            UnsafePointer(to=a).bitcast[UInt8](),
            UInt(N),  # smax
            Int(0),   # c
            UInt(N),  # n
        )
    else:
        # Linux / BSD path. void return.
        external_call["explicit_bzero", NoneType](
            UnsafePointer(to=a).bitcast[UInt8](),
            UInt(N),
        )


@always_inline
def zeroize_inline_array_u32[N: Int](mut a: Array[UInt32, N]):
    """No-elide secure-zero for an `InlineArray[UInt32, N]`.

    Sha256's `state` field is `InlineArray[UInt32, 8]`; the destructor
    needs to clear it. We bitcast to byte-pointer and zero N*4 bytes.

    Same SAFETY discipline as `zeroize_inline_array[N]`.
    """
    comptime if CompilationTarget.is_macos():
        var _e = external_call["memset_s", Int](
            UnsafePointer(to=a).bitcast[UInt8](),
            UInt(N * 4),
            Int(0),
            UInt(N * 4),
        )
    else:
        external_call["explicit_bzero", NoneType](
            UnsafePointer(to=a).bitcast[UInt8](),
            UInt(N * 4),
        )


@always_inline
def zeroize_inline_array_u64[N: Int](mut a: Array[UInt64, N]):
    """No-elide secure-zero for an `InlineArray[UInt64, N]`.

    Sha384/512's `_state` field is `InlineArray[UInt64, 8]` (FIPS 180-4
    SHA-512 family uses 64-bit state words). The destructor needs to
    clear it. We bitcast to byte-pointer and zero N*8 bytes.

    For the UInt64 state words of SHA-384/512.
    Same SAFETY discipline as `zeroize_inline_array[N]`.
    """
    comptime if CompilationTarget.is_macos():
        var _e = external_call["memset_s", Int](
            UnsafePointer(to=a).bitcast[UInt8](),
            UInt(N * 8),
            Int(0),
            UInt(N * 8),
        )
    else:
        external_call["explicit_bzero", NoneType](
            UnsafePointer(to=a).bitcast[UInt8](),
            UInt(N * 8),
        )
