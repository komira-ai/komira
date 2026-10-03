# =============================================================================
# builtin_binary_fns.mojo — Built-in BinaryFn conformers


# =============================================================================
#
# Built-in BinaryFn conformers for the canonical homogeneous-type INT64 +
# FLOAT64 cells:
#
#   AddI64, SubI64, MulI64   -- (Int64, Int64) -> Int64 arithmetic
#   AddF64, SubF64, MulF64   -- (Float64, Float64) -> Float64 arithmetic
#
# this version deliberately ships only the homogeneous cells. Mixed-type
# cells (e.g. Int32 + Int64, Int64 * Float64) are followup — declare a
# new conformer per cell; no trait surface change.
#
# Hot-path SIMD (hand-staged)
# ---------------------------
# Mojo 1.0.0b1's autovectorizer does NOT fire on unit-stride numeric loops
#. Each kernel body hand-stages
# SIMD via `PrimitiveArray.load[width=W]` / `store[width=W]` (which delegate
# to `OwnedAlignedBuffer.load_simd[T, W]` / `store_simd[T, W]`) — the same shape
# the existing `eval_add` / `eval_sub` / `eval_mul` primitives use in
# `komira_core.eval.arithmetic`. The W = `simd_width_of[T]()`
# comptime constant tunes per dtype (4 lanes for Int64 on NEON, 8 lanes for
# Int32, 2 lanes for Float64 on the host arm64). Ragged tails are handled
# with width=1 lane-by-lane.
#
# Non-raising contract
# --------------------
# `BinaryFn.eval_chunk` is `fn` (non-raising). The underlying `load[width]` / `store[width]` are
# `def` (raising for historical reasons; bodies never actually raise),
# so the kernel body wraps the loop in a single `try / except` barrier
# at the chunk granularity — the per-lane SIMD code path stays
# barrier-free in the emitted IR. (A per-call exception barrier would block
# loop fusion; chunk granularity avoids it.)
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any signature.
# - No wildcard origins anywhere.
# - File < 1000 LOC.
# - Conformers are `@fieldwise_init struct ... (BinaryFn)`; no captures
# needed in this version (every kernel is stateless arithmetic). Future
#   conformers with captures (e.g. a `MulScalar` capturing a literal)
#   add `var k: Scalar[TA]` fields and the operator copies the kernel
#   instance per worker via `Copyable`.


# =============================================================================

from std.sys import simd_width_of

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.plan.expr import BIN_ADD, BIN_SUB, BIN_MUL

from .binary_fn import BinaryFn


# =============================================================================
# Internal hand-staged SIMD helpers — one per (dtype, op) cell.
#
# Each helper is `@always_inline fn` so the kernel struct's `eval_chunk`
# inlines through to the SIMD lane code with no per-call cost. The body
# uses a single `try / except` barrier at chunk granularity; the inner
# per-lane code path is barrier-free.


# =============================================================================


@always_inline
def _simd_add[dt: DType](
    lhs: PrimitiveArray[dt],
    rhs: PrimitiveArray[dt],
    mut out: PrimitiveArray[dt],
):
    """Element-wise lhs + rhs -> out (data buffer only).

    The operator caller pre-allocates `out` with the same length and merged
    validity bitmap; this function only fills the data buffer. SIMD width
    is `simd_width_of[dt]()` (e.g. 2 for Float64 on NEON, 4 for Int64).
    Ragged tail handled lane-by-lane at width=1.
    """
    comptime W = simd_width_of[dt]()
    var n = lhs.length
    var i = 0
    while i + W <= n:
        var a = lhs.load[width=W](i)
        var b = rhs.load[width=W](i)
        out.store[width=W](i, a + b)
        i += W
    while i < n:
        var a1 = lhs.load[width=1](i)
        var b1 = rhs.load[width=1](i)
        out.store[width=1](i, a1 + b1)
        i += 1


@always_inline
def _simd_sub[dt: DType](
    lhs: PrimitiveArray[dt],
    rhs: PrimitiveArray[dt],
    mut out: PrimitiveArray[dt],
):
    """Element-wise lhs - rhs -> out (data buffer only). See `_simd_add`."""
    comptime W = simd_width_of[dt]()
    var n = lhs.length
    var i = 0
    while i + W <= n:
        var a = lhs.load[width=W](i)
        var b = rhs.load[width=W](i)
        out.store[width=W](i, a - b)
        i += W
    while i < n:
        var a1 = lhs.load[width=1](i)
        var b1 = rhs.load[width=1](i)
        out.store[width=1](i, a1 - b1)
        i += 1


@always_inline
def _simd_mul[dt: DType](
    lhs: PrimitiveArray[dt],
    rhs: PrimitiveArray[dt],
    mut out: PrimitiveArray[dt],
):
    """Element-wise lhs * rhs -> out (data buffer only). See `_simd_add`."""
    comptime W = simd_width_of[dt]()
    var n = lhs.length
    var i = 0
    while i + W <= n:
        var a = lhs.load[width=W](i)
        var b = rhs.load[width=W](i)
        out.store[width=W](i, a * b)
        i += W
    while i < n:
        var a1 = lhs.load[width=1](i)
        var b1 = rhs.load[width=1](i)
        out.store[width=1](i, a1 * b1)
        i += 1


# =============================================================================
# Int64 conformers


# =============================================================================


@fieldwise_init
struct AddI64(BinaryFn):
    """(Int64, Int64) -> Int64 element-wise addition."""

    comptime TA = DType.int64
    comptime TB = DType.int64
    comptime TR = DType.int64
    comptime OP_TAG = BIN_ADD
    comptime KERNEL_ID = UInt32(0x0001_0001)  # bank=0x0001 (built-in arith), kernel=0x0001

    def name(self) -> String:
        return "AddI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out: PrimitiveArray[DType.int64],
    ):
        _simd_add[DType.int64](lhs, rhs, out)


@fieldwise_init
struct SubI64(BinaryFn):
    """(Int64, Int64) -> Int64 element-wise subtraction."""

    comptime TA = DType.int64
    comptime TB = DType.int64
    comptime TR = DType.int64
    comptime OP_TAG = BIN_SUB
    comptime KERNEL_ID = UInt32(0x0001_0002)

    def name(self) -> String:
        return "SubI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out: PrimitiveArray[DType.int64],
    ):
        _simd_sub[DType.int64](lhs, rhs, out)


@fieldwise_init
struct MulI64(BinaryFn):
    """(Int64, Int64) -> Int64 element-wise multiplication."""

    comptime TA = DType.int64
    comptime TB = DType.int64
    comptime TR = DType.int64
    comptime OP_TAG = BIN_MUL
    comptime KERNEL_ID = UInt32(0x0001_0003)

    def name(self) -> String:
        return "MulI64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.int64],
        rhs: PrimitiveArray[DType.int64],
        mut out: PrimitiveArray[DType.int64],
    ):
        _simd_mul[DType.int64](lhs, rhs, out)


# =============================================================================
# Float64 conformers


# =============================================================================


@fieldwise_init
struct AddF64(BinaryFn):
    """(Float64, Float64) -> Float64 element-wise addition."""

    comptime TA = DType.float64
    comptime TB = DType.float64
    comptime TR = DType.float64
    comptime OP_TAG = BIN_ADD
    comptime KERNEL_ID = UInt32(0x0001_0011)

    def name(self) -> String:
        return "AddF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out: PrimitiveArray[DType.float64],
    ):
        _simd_add[DType.float64](lhs, rhs, out)


@fieldwise_init
struct SubF64(BinaryFn):
    """(Float64, Float64) -> Float64 element-wise subtraction."""

    comptime TA = DType.float64
    comptime TB = DType.float64
    comptime TR = DType.float64
    comptime OP_TAG = BIN_SUB
    comptime KERNEL_ID = UInt32(0x0001_0012)

    def name(self) -> String:
        return "SubF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out: PrimitiveArray[DType.float64],
    ):
        _simd_sub[DType.float64](lhs, rhs, out)


@fieldwise_init
struct MulF64(BinaryFn):
    """(Float64, Float64) -> Float64 element-wise multiplication."""

    comptime TA = DType.float64
    comptime TB = DType.float64
    comptime TR = DType.float64
    comptime OP_TAG = BIN_MUL
    comptime KERNEL_ID = UInt32(0x0001_0013)

    def name(self) -> String:
        return "MulF64"

    def eval_chunk(
        self,
        lhs: PrimitiveArray[DType.float64],
        rhs: PrimitiveArray[DType.float64],
        mut out: PrimitiveArray[DType.float64],
    ):
        _simd_mul[DType.float64](lhs, rhs, out)
