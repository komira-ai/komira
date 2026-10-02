# =============================================================================
# src/komira_kafka_server/wire/crc32c.mojo — CRC-32C (Castagnoli) over a byte span
# =============================================================================
#
# The Kafka RecordBatch-v2 batch header carries a CRC-32C
# (Castagnoli) checksum over the batch bytes from the `attributes` field
# onward. Kafka uses CRC-32C (reflected polynomial 0x82F63B78), NOT the
# IEEE-802.3 CRC-32.
#
# HARDWARE INTRINSIC: on two targets the CRC is computed with the CPU's native
# CRC32C instruction —
#   * x86-64:      `llvm.x86.sse42.crc32.32.{8,64}` (SSE4.2 `crc32` instruction).
#   * macOS arm64: `llvm.aarch64.crc32c{b,h,w,x}` (ARMv8 CRC extension, present
#     on every Apple Silicon CPU).
# Every other target, including Linux aarch64, takes the portable
# table-driven path. This is
# NOT an FFI call — the intrinsic lowers to a single CPU instruction per 1/8
# bytes, so a Produce/Fetch hot path pays no library-dispatch overhead.
#
# Encapsulation: the PUBLIC API takes `Span[UInt8, _]` / `List[UInt8]`
# and returns `UInt32`. ZERO UnsafePointer crosses the module boundary; the
# intrinsics consume scalar `UInt8`/`UInt64` values pulled out of the span by a
# bounds-safe index, never a raw pointer.
# =============================================================================

from std.sys.intrinsics import llvm_intrinsic
from std.sys.info import CompilationTarget


# CRC-32C reflected (Castagnoli) polynomial — the table-fallback constant.
comptime _CRC32C_POLY: UInt32 = 0x82F63B78


# -----------------------------------------------------------------------------
# Hardware intrinsic wrappers (one CPU instruction each).
# -----------------------------------------------------------------------------
#
# aarch64 `crc32c{b,h,w,x}`: (i32 acc, iN data) -> i32, accumulator-style.
# x86 `crc32`: (i32 acc, i8/i64 data) -> i32, same accumulator shape.


@always_inline
def _hw_crc32c_u8(acc: UInt32, b: UInt8) -> UInt32:
    comptime if CompilationTarget.is_x86():
        return llvm_intrinsic["llvm.x86.sse42.crc32.32.8", UInt32](acc, b)
    else:
        return llvm_intrinsic["llvm.aarch64.crc32cb", UInt32](acc, UInt32(b))


@always_inline
def _hw_crc32c_u64(acc: UInt32, v: UInt64) -> UInt32:
    comptime if CompilationTarget.is_x86():
        # x86 crc32 q-form returns i64; truncate the (upper-zero) result to i32.
        var r = llvm_intrinsic["llvm.x86.sse42.crc32.64.64", UInt64](
            UInt64(acc), v
        )
        return UInt32(r & UInt64(0xFFFFFFFF))
    else:
        return llvm_intrinsic["llvm.aarch64.crc32cx", UInt32](acc, v)


# -----------------------------------------------------------------------------
# Table fallback (portable; used on every target except x86-64 and macOS arm64).
# -----------------------------------------------------------------------------


@always_inline
def _crc32c_table_entry(byte_val: Int) -> UInt32:
    var crc = UInt32(byte_val)
    for _ in range(8):
        if (crc & UInt32(1)) != UInt32(0):
            crc = (crc >> UInt32(1)) ^ _CRC32C_POLY
        else:
            crc = crc >> UInt32(1)
    return crc


# -----------------------------------------------------------------------------
# Public API — CRC-32C over a borrowed byte span / owned list.
# -----------------------------------------------------------------------------


def crc32c_span(data: Span[UInt8, _]) -> UInt32:
    """CRC-32C (Castagnoli, reflected, init 0xFFFFFFFF, xorout 0xFFFFFFFF) over
    `data`. Uses the hardware CRC32C instruction on x86-64 and macOS arm64,
    and a table-driven fallback on every other target (Linux aarch64
    included). No pointer crosses the boundary
    — the span is indexed bytewise."""
    var n = len(data)
    var crc = UInt32(0xFFFFFFFF)

    # Hardware CRC32C path on the two supported targets: x86_64 (SSE4.2) and
    # Apple-Silicon arm64 (ARMv8 CRC extension — universal on Apple Silicon).
    # Any other arch (a future non-mac arm64 without the CRC extension, etc.)
    # takes the portable table fallback.
    comptime if CompilationTarget.is_x86() or CompilationTarget.is_macos():
        # Hardware path: fold 8 bytes at a time via the wide intrinsic, then
        # the byte intrinsic for the tail.
        var i = 0
        while i + 8 <= n:
            var v = UInt64(0)
            for j in range(8):
                v |= UInt64(data[i + j]) << UInt64(8 * j)
            crc = _hw_crc32c_u64(crc, v)
            i += 8
        while i < n:
            crc = _hw_crc32c_u8(crc, data[i])
            i += 1
        return crc ^ UInt32(0xFFFFFFFF)
    else:
        # Portable table path (built on the stack; cheap, stays in L1).
        var table = Array[UInt32, 256](uninitialized=True)
        comptime for k in range(256):
            table[k] = _crc32c_table_entry(k)
        for i in range(n):
            var idx = Int((crc ^ UInt32(data[i])) & UInt32(0xFF))
            crc = (crc >> UInt32(8)) ^ table[idx]
        return crc ^ UInt32(0xFFFFFFFF)


@always_inline
def crc32c_list(data: List[UInt8]) -> UInt32:
    """CRC-32C over an owned `List[UInt8]` (convenience wrapper over
    `crc32c_span`)."""
    return crc32c_span(Span(data))
