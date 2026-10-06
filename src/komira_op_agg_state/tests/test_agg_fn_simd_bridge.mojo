# =============================================================================
# test_agg_fn_simd_bridge.mojo — _AggFnFusedKernel typed-bridge fns
# =============================================================================
#
# UDF-PHASE-B3-7-PREREQ (RFC §6.4 prerequisite primitive). Tests the
# `_invoke_update_chunk[G: _AggFnFusedKernel, W]` + `_invoke_finalize_simd[G:
# _AggFnFusedKernel]` free functions in
# `komira_op_agg_state/agg_fn_acc.mojo`. These functions are the
# typed bridges that let a comptime-`G: _AggFnFusedKernel`-bounded call site
# dispatch into the `G.update_chunk[W]` and `G.finalize` static methods
# (the _AggFnFusedKernel surface from B3-2). They would FAIL at pre-B3-7-PREREQ
# HEAD because the functions did not exist.
#
# What is NOT tested here (deferred to v0.5):
#   - The State <-> STATE rebind helpers. These are blocked by Mojo
#     Mojo's requirement that `rebind[T]` source values be
#     ImplicitlyCopyable, which PodState is not (it's Copyable +
#     Movable + Deinitable). The blocker is documented
#     in agg_fn_acc.mojo (see the `NOTE on the State -> STATE rebind
#     helper:` block).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_almost_equal

from komira_udf.agg_fn import AggFn, PodState
from komira_udf.schema_descriptor import schema_of, DT_F64
from komira_kernels.simd_of import SimdOf
from komira_op_agg_state.agg_fn_fused_kernel import _AggFnFusedKernel

from komira_op_agg_state.agg_fn_acc import (
    _invoke_update_chunk,
    _invoke_finalize_simd,
)


# =============================================================================
# Fixture — Sum (mirrors an internal test:Sum)
# =============================================================================


@fieldwise_init
struct F64Row(Copyable, Movable):
    var x: Float64


@fieldwise_init
struct F64OutRow(Copyable, Movable):
    var y: Float64


@fieldwise_init
struct SumState(PodState):
    var sum: Float64


@fieldwise_init
struct Sum(_AggFnFusedKernel):
    # Legacy AggFn surface.
    comptime InRow = F64Row
    comptime InputSchema = schema_of["x", DT_F64]()
    comptime OutputSchema = schema_of["sum_x", DT_F64]()
    comptime OutType = DType.float64
    comptime State = SumState
    comptime UDF_ID = UInt32(0xB377_0001)

    # NEW _AggFnFusedKernel surface.
    comptime T_IN = F64Row
    comptime T_OUT = F64OutRow
    comptime STATE = SumState

    # Legacy `self` AggFn methods.
    def init(self) -> SumState:
        return SumState(0.0)

    def update(self, mut s: SumState, row: F64Row):
        self.update_scalar(s, row.x)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumState, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])

    def merge(self, a: SumState, b: SumState) -> SumState:
        return SumState(a.sum + b.sum)

    def finalize(self, s: SumState) -> Scalar[DType.float64]:
        return s.sum

    # NEW @staticmethod _AggFnFusedKernel methods.
    @staticmethod
    def init() -> SumState:
        return SumState(0.0)

    @staticmethod
    def update_chunk[W: Int](mut state: SumState, input: SimdOf[F64Row, W]):
        state.sum += input.get_f64[0]().reduce_add()

    @staticmethod
    def update(mut state: SumState, input: F64Row):
        state.sum += input.x

    @staticmethod
    def merge(mut a: SumState, b: SumState):
        a.sum += b.sum

    @staticmethod
    def finalize(state: SumState) -> F64OutRow:
        return F64OutRow(y=state.sum)


# =============================================================================
# Helper — build a SimdOf[F64Row, W] from a Float64 SIMD
# =============================================================================


def _build_chunk_w4(
    v0: Float64, v1: Float64, v2: Float64, v3: Float64,
) -> SimdOf[F64Row, 4]:
    var c = SimdOf[F64Row, 4].zero()
    c.set_f64[0](SIMD[DType.float64, 4](v0, v1, v2, v3))
    return c^


def _build_chunk_w8(
    v0: Float64, v1: Float64, v2: Float64, v3: Float64,
    v4: Float64, v5: Float64, v6: Float64, v7: Float64,
) -> SimdOf[F64Row, 8]:
    var c = SimdOf[F64Row, 8].zero()
    c.set_f64[0](SIMD[DType.float64, 8](v0, v1, v2, v3, v4, v5, v6, v7))
    return c^


# =============================================================================
# Tests
# =============================================================================


def test_invoke_update_chunk_w4_folds_chunk_into_state() raises:
    """_invoke_update_chunk[Sum, 4] folds a 4-lane SimdOf into a SumState."""
    var s = Sum.init()
    var chunk = _build_chunk_w4(1.5, 2.5, 3.5, 4.5)
    _invoke_update_chunk[Sum, 4](s, chunk)
    assert_almost_equal(s.sum, 12.0)


def test_invoke_update_chunk_w8_folds_chunk_into_state() raises:
    """_invoke_update_chunk[Sum, 8] folds an 8-lane chunk: sum = 36.0."""
    var s = Sum.init()
    var chunk = _build_chunk_w8(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0)
    _invoke_update_chunk[Sum, 8](s, chunk)
    assert_almost_equal(s.sum, 36.0)


def test_invoke_update_chunk_accumulates_across_calls() raises:
    """Multiple calls to _invoke_update_chunk accumulate into the same state."""
    var s = Sum.init()
    var c1 = _build_chunk_w4(1.0, 2.0, 3.0, 4.0)
    var c2 = _build_chunk_w4(5.0, 6.0, 7.0, 8.0)
    _invoke_update_chunk[Sum, 4](s, c1)
    _invoke_update_chunk[Sum, 4](s, c2)
    assert_almost_equal(s.sum, 36.0)


def test_invoke_finalize_simd_produces_t_out() raises:
    """_invoke_finalize_simd[Sum] produces the typed F64OutRow output.

    Note: `_invoke_finalize_simd` takes `var state` (consuming move)
    because `_AggFnFusedKernel.finalize` takes `Self.STATE` by value. Test
    passes `s^` to move-in.
    """
    var s = Sum.init()
    var chunk = _build_chunk_w4(10.0, 20.0, 30.0, 40.0)
    _invoke_update_chunk[Sum, 4](s, chunk)
    var out = _invoke_finalize_simd[Sum](s^)
    assert_almost_equal(out.y, 100.0)


def test_invoke_update_chunk_byte_identical_to_loop() raises:
    """The bridge's update_chunk path produces the same state as the
    parent-trait per-row update path (the _AggFnFusedKernel correctness oracle)."""
    var s_chunked = Sum.init()
    var chunk = _build_chunk_w8(0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5)
    _invoke_update_chunk[Sum, 8](s_chunked, chunk)

    # Scalar oracle: same values via per-row update.
    var s_scalar = Sum.init()
    var vals = SIMD[DType.float64, 8](0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5)
    for i in range(8):
        Sum.update(s_scalar, F64Row(x=vals[i]))

    assert_almost_equal(s_chunked.sum, s_scalar.sum)
    assert_almost_equal(s_chunked.sum, 32.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
