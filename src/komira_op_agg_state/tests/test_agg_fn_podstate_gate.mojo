# =============================================================================
# test_agg_fn_podstate_gate.mojo — the real PodState gap6 gate ()
# =============================================================================
#
# UDF-PODSTATE-COMPILE-TIME-GATE. Proves that the `assert_pod_state[S]()`
# comptime gate (komira_eval/pod_state_gate.mojo) — forced from
# `AggFnAcc[F].__init__` — accepts every gap6-safe `AggFn.State` shape and
# REJECTS a heap-owning one.
#
# POSITIVE guard (this file, runnable):
#   - `AggFnAcc[GoodFlatAgg]` (flat PodScalar State: Float64 + Int64) compiles
#     + constructs — the gate passes, no false rejection.
#   - `AggFnAcc[GoodHllAgg]` (InlineArray[Int64, 16] State — the HLL workaround
#     carve-out) compiles + constructs — the InlineArray-of-PodScalar carve-out
#     is NOT wrongly rejected.
#   - `assert_pod_state[...]` called directly on both good states.
#
# NEGATIVE compile (the load-bearing proof — see the §FAILS-TO-COMPILE block
# at the bottom): an `AggFn` whose `State` has `var bad: List[Int]` MUST FAIL
# TO COMPILE. The repo has no bazel-runnable negative-compile harness, so the
# bad conformer is kept commented-out + branded; the manual proof (uncomment,
# build, observe the `constrained[]` message, re-comment) is documented in the
# delivery memo. The probe at `/tmp/probe_assert_bad.mojo` (pre-land) already
# confirmed the exact firing message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.collections import Array

from komira_udf.agg_fn import AggFn, PodState
from komira_agg.pod_state_gate import (
    assert_pod_state,
    _is_pod_field,
    _is_pod_scalar,
    _is_pod_inline_array,
)
from komira_udf.schema_descriptor import schema_of, DT_F64
from komira_op_agg_state.agg_fn_acc import AggFnAcc


# =============================================================================
# §1 — GOOD conformers (must compile + pass the gate)
# =============================================================================

# --- (a) flat PodScalar State ---

@fieldwise_init
struct GoodFlatRow(Copyable, Movable):
    var v: Float64


@fieldwise_init
struct GoodFlatState(PodState):
    """Two flat PodScalar fields — the common case."""
    var sum: Float64
    var count: Int64


@fieldwise_init
struct GoodFlatAgg(AggFn):
    comptime InRow = GoodFlatRow
    comptime InputSchema = schema_of["v", DT_F64]()
    comptime OutputSchema = schema_of["out", DT_F64]()
    comptime OutType = DType.float64
    comptime State = GoodFlatState
    comptime UDF_ID = UInt32(70001)

    def init(self) -> GoodFlatState:
        return GoodFlatState(0.0, 0)

    def update(self, mut s: GoodFlatState, row: GoodFlatRow):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: GoodFlatState, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])
        s.count += 1

    def merge(self, a: GoodFlatState, b: GoodFlatState) -> GoodFlatState:
        return GoodFlatState(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: GoodFlatState) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count != 0 else 0.0


# --- (b) InlineArray[PodScalar, N] State — the HLL workaround carve-out ---

@fieldwise_init
struct GoodHllRow(Copyable, Movable):
    var v: Float64


@fieldwise_init
struct GoodHllState(PodState):
    """An InlineArray[Int64, 16] register array + a scalar — the documented
    HLL-style heap-free State. The carve-out the gate must NOT reject."""
    var registers: Array[Int64, 16]
    var n: Int64


@fieldwise_init
struct GoodHllAgg(AggFn):
    comptime InRow = GoodHllRow
    comptime InputSchema = schema_of["v", DT_F64]()
    comptime OutputSchema = schema_of["out", DT_F64]()
    comptime OutType = DType.float64
    comptime State = GoodHllState
    comptime UDF_ID = UInt32(70002)

    def init(self) -> GoodHllState:
        return GoodHllState(Array[Int64, 16](fill=0), 0)

    def update(self, mut s: GoodHllState, row: GoodHllRow):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: GoodHllState, *vals: *Ts):
        var idx = Int(rebind[Float64](vals[0])) % 16
        s.registers[idx] += 1
        s.n += 1

    def merge(self, a: GoodHllState, b: GoodHllState) -> GoodHllState:
        var regs = Array[Int64, 16](fill=0)
        for i in range(16):
            regs[i] = b.registers[i] if b.registers[i] > a.registers[i] else a.registers[i]
        return GoodHllState(regs^, a.n + b.n)

    def finalize(self, s: GoodHllState) -> Scalar[DType.float64]:
        return Float64(s.n)


# =============================================================================
# §2 — POSITIVE guard tests
# =============================================================================

def test_flat_pod_state_passes_gate() raises:
    # Constructing AggFnAcc[GoodFlatAgg] FORCES assert_pod_state[GoodFlatState]
    # (the __init__ forcing site). If the gate wrongly rejected a flat
    # PodScalar State this would not compile.
    var acc = AggFnAcc[GoodFlatAgg](GoodFlatAgg())
    assert_equal(acc.num_groups(), 0, "fresh AggFnAcc has 0 groups")
    acc.ensure_capacity(2)
    assert_equal(acc.num_groups(), 2, "ensure_capacity(2) seeds 2 groups")


def test_inline_array_pod_state_passes_gate() raises:
    # Constructing AggFnAcc[GoodHllAgg] FORCES assert_pod_state[GoodHllState],
    # which contains an InlineArray[Int64, 16] field — the HLL carve-out. The
    # gate must NOT reject it (false-positive guard).
    var acc = AggFnAcc[GoodHllAgg](GoodHllAgg())
    assert_equal(acc.num_groups(), 0, "fresh AggFnAcc has 0 groups")
    acc.ensure_capacity(1)
    assert_equal(acc.num_groups(), 1, "ensure_capacity(1) seeds 1 group")


def test_assert_pod_state_direct() raises:
    # Direct invocation on both good states — comptime no-op on success.
    assert_pod_state[GoodFlatState]()
    assert_pod_state[GoodHllState]()
    assert_true(True, "assert_pod_state[good] compiled (the comptime gate passed)")


def test_pod_field_predicates() raises:
    # The leaf predicates discriminate scalar / InlineArray / heap correctly.
    assert_true(_is_pod_scalar[Float64](), "Float64 is a PodScalar")
    assert_true(_is_pod_scalar[Int64](), "Int64 is a PodScalar")
    assert_true(_is_pod_scalar[Bool](), "Bool is a PodScalar")
    assert_true(not _is_pod_scalar[String](), "String is NOT a PodScalar")

    assert_true(
        _is_pod_inline_array[Array[Int64, 16]](),
        "InlineArray[Int64, 16] is a pod InlineArray",
    )
    assert_true(
        _is_pod_inline_array[Array[Float64, 8]](),
        "InlineArray[Float64, 8] is a pod InlineArray",
    )
    assert_true(
        not _is_pod_inline_array[Array[String, 4]](),
        "InlineArray[String, 4] is NOT a pod InlineArray (String element"
        " rejected — the carve-out validates the element type)",
    )
    assert_true(
        not _is_pod_inline_array[Int64](),
        "a flat scalar is not classified as an InlineArray",
    )

    assert_true(_is_pod_field[Float64](), "Float64 field is gap6-safe")
    assert_true(
        _is_pod_field[Array[UInt8, 32]](),
        "InlineArray[UInt8, 32] field is gap6-safe",
    )
    assert_true(not _is_pod_field[String](), "String field is NOT gap6-safe")
    assert_true(not _is_pod_field[List[Int]](), "List[Int] field is NOT gap6-safe")


# =============================================================================
# §FAILS-TO-COMPILE — the negative-compile proof (commented out)
# =============================================================================
#
# Uncomment the conformer + the construction below and run a build:
#   bazel build an internal Bazel target
# It MUST FAIL with the gate's `constrained[]` message, e.g.:
#   note: constraint failed: AggFn.State has a heap-owning field
#   (String/List/Set/OwnedPointer/nested struct) — not PodState/gap6-safe. ...
# Re-comment after observing the failure. (PodState is a no-op marker trait —
# `List[Int]` conforms to Copyable+Movable+Deinitable — so WITHOUT
# the gate this compiles and UB's at flush-partial. The gate is what rejects
# it.)
#
# @fieldwise_init
# struct BadListRow(Copyable, Movable):
#     var v: Float64
#
#
# @fieldwise_init
# struct BadListState(PodState):
#     var sum: Float64
#     var bad: List[Int]   # heap-owning — gap6 trap. MUST be rejected.
#
#
# @fieldwise_init
# struct BadListAgg(AggFn):
#     comptime InRow = BadListRow
#     comptime InputSchema = schema_of["v", DT_F64]()
#     comptime OutputSchema = schema_of["out", DT_F64]()
#     comptime OutType = DType.float64
#     comptime State = BadListState
#     comptime UDF_ID = UInt32(70099)
#
#     fn init(self) -> BadListState:
#         return BadListState(0.0, List[Int]())
#
#     fn update(self, mut s: BadListState, row: BadListRow):
#         self.update_scalar(s, row.v)
#
#     fn update_scalar[*Ts: Copyable & Movable](self, mut s: BadListState, *vals: *Ts):
#         s.sum += rebind[Float64](vals[0])
#
#     fn merge(self, a: BadListState, b: BadListState) -> BadListState:
#         return a
#
#     fn finalize(self, s: BadListState) -> Scalar[DType.float64]:
#         return s.sum
#
#
# def test_bad_list_state_must_not_compile() raises:
#     # CONSTRUCTING AggFnAcc[BadListAgg] forces assert_pod_state[BadListState]
#     # -> the List[Int] field trips the gate -> FAILS TO COMPILE.
#     var acc = AggFnAcc[BadListAgg](BadListAgg())
#     _ = acc.num_groups()


def main() raises:
    var suite = TestSuite()
    suite.test[test_flat_pod_state_passes_gate]()
    suite.test[test_inline_array_pod_state_passes_gate]()
    suite.test[test_assert_pod_state_direct]()
    suite.test[test_pod_field_predicates]()
    suite^.run()
