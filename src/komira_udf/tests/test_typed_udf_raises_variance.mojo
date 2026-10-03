# =============================================================================
# test_typed_udf_raises_variance.mojo
# WHAT IT COSTS TO LET A TYPED UDF FAIL — the three language facts, pinned
# =============================================================================
#
# THE CAPABILITY. A customer UDF that divides, parses or indexes must be able
# to FAIL and surface its own error, so the typed UDF oracles
# (`MapFn.run_row`, `FilterFn.keep_row`) are declared `raises`. The engine
# reaches them by building the UDF's `InRow` itself
# (`komira_udf.row_builder._build_row[R]`); there is no variadic het-pack
# oracle on the traits.
#
# A non-raising function passed where a non-raising comptime fn parameter is
# expected is refused:
#
#     error: value passed to 'f' cannot be converted from
#       'def safe_div(a: Float64, b: Float64) raises thin -> Float64'
#       to 'def($1|0, $1|1) thin -> Float64'
#
# ⛔ AND WIDENING A VARIADIC TRAIT METHOD TO `raises` WITH NON-RAISING
# CONFORMERS DOES NOT FAIL TO COMPILE; it CRASHES THE COMPILER (SIGSEGV /
# stack overflow, `rc=139`, "Please submit a bug report"). Ten lines
# reproduce it on Mojo 1.0.0 (ed45d567):
#
#     trait T(Movable, Copyable, Deinitable):
#         def rs[*Ts: Copyable & Movable](mut self, *vals: *Ts) raises -> Int64: ...
#     @fieldwise_init
#     struct C(T, Copyable, Movable):
#         def rs[*Ts: Copyable & Movable](mut self, *vals: *Ts) -> Int64:
#             return rebind[Int64](vals[0])
#     def drive[F: T](var f: F, x: Int64) raises -> Int64:
#         var l = f^
#         return l.rs(x)
#     def main() raises: print(drive(C(), 7))
#
# The three tests below are the BISECT of that crash, kept as executable facts
# because each one is what someone will otherwise re-derive by hand:
#
#   1. `raises` on a NON-variadic trait method + a non-raising conformer -> FINE.
#      This is the one that matters: the per-row path calls `run_row` /
#      `keep_row`, so every non-raising conformer keeps conforming untouched.
#   2. `raises` on a VARIADIC trait method + a conformer that is ALSO `raises`
#      -> FINE. Kept because it pins the boundary of the compiler crash, which
#      is what makes adding a variadic oracle a bad idea rather than a neutral
#      one.
#   3. a non-raising `def` still binds to a `raises thin` comptime fn parameter
#      -> FINE. So `Map1`/`Map2`'s `f` widens with no call-site edit.
#
#   ⚠ THE `raises` RIPPLE THROUGH THE ADAPTERS is a separate cost this file
#   does not measure. The map adapters are `raises` (`MapFnRT.write_one`,
#   `EvaluatorAdapterFor_Map.emit_projected`). For the FILTER adapters:
#     - row-format `RowEvaluatorAdapterFor_Filter` — `eval_one` AND
#       `eval_batch` read a `RowBlock` via the non-raising `read_fixed[DT]`.
#     - runtime-row `RowEvaluatorAdapterFor_Filter` — `eval_batch` is
#       `raises` (its `RowCellSource` reads raise).
#     - `Predicate.eval_scalar` is NON-raising, and `FilterFn` refines
#       `Predicate`, so widening it is the one change that reaches every
#       FilterFn conformer — each implements `eval_scalar` by hand.
#
# ⚠ WHY LOCAL TRAITS AND NOT `MapFn` ITSELF. These traits are structurally
# identical to a variadic het-pack oracle (same variadic shape, same
# `mut self`, same `Scalar[Self.OutType]` return) and cost nothing else, so
# the facts are pinned in isolation.
# =============================================================================

from std.testing import assert_equal, assert_raises, TestSuite


# =============================================================================
# FACT 1 — `raises` on a NON-variadic trait method is transparently backward
# compatible: the non-raising conformer still conforms, AND a raising sibling
# conformer works. This is `MapFn.run_row`'s shape.
# =============================================================================
trait RowOracle(Movable, Copyable, Deinitable):
    comptime OutType: DType

    def run_row(mut self, x: Int64) raises -> Scalar[Self.OutType]:
        ...


@fieldwise_init
struct _Infallible(RowOracle, Copyable, Movable):
    comptime OutType = DType.int64

    # NO `raises` — the shape of every conformer in `src/` today.
    def run_row(mut self, x: Int64) -> Scalar[Self.OutType]:
        return x * 10


@fieldwise_init
struct _Fallible(RowOracle, Copyable, Movable):
    comptime OutType = DType.int64

    def run_row(mut self, x: Int64) raises -> Scalar[Self.OutType]:
        if x == 0:
            raise Error("run_row: refusing zero")
        return 100 // x


def _drive_row[F: RowOracle](var f: F, x: Int64) raises -> Scalar[F.OutType]:
    var local = f^
    return local.run_row(x)


def test_nonvariadic_raises_admits_a_nonraising_conformer() raises:
    """The half that makes the widening look free. It IS free — here."""
    assert_equal(_drive_row(_Infallible(), 7), 70)


def test_nonvariadic_raises_admits_a_raising_conformer() raises:
    assert_equal(_drive_row(_Fallible(), 4), 25)
    with assert_raises(contains="refusing zero"):
        _ = _drive_row(_Fallible(), 0)


# =============================================================================
# FACT 2 — the VARIADIC het-pack oracle (`MapFn.run_scalar`'s shape). `raises`
# here is legal ONLY when the conformer is `raises` too; the non-raising
# conformer crashes the compiler (header). So this test is simultaneously the
# escape hatch and the reason the fix is not free.
# =============================================================================
trait PackOracle(Movable, Copyable, Deinitable):
    comptime OutType: DType

    def run_scalar[*Ts: Copyable & Movable](
        mut self, *vals: *Ts
    ) raises -> Scalar[Self.OutType]:
        ...


@fieldwise_init
struct _PackFallible(PackOracle, Copyable, Movable):
    comptime OutType = DType.float64

    # `raises` MANDATORY here — omit it and the compiler stack-overflows.
    def run_scalar[*Ts: Copyable & Movable](
        mut self, *vals: *Ts
    ) raises -> Scalar[Self.OutType]:
        var b = rebind[Float64](vals[1])
        if b == 0.0:
            raise Error("run_scalar: division by zero")
        return rebind[Float64](vals[0]) / b


def _drive_pack[F: PackOracle](
    var f: F, a: Float64, b: Float64
) raises -> Scalar[F.OutType]:
    var local = f^
    return local.run_scalar(a, b)


def test_variadic_raises_carries_an_error_out_of_the_perlane_oracle() raises:
    """A variadic het-pack oracle CAN carry an error out, provided the
    conformer is `raises` too.

    `run_row`/`keep_row` are the executing surface, so this is a pure
    language fact, which is why the local `PackOracle` trait is worth
    keeping: it records that the variadic shape is `raises`-able ONLY with a
    `raises` conformer, and crashes the compiler otherwise."""
    assert_equal(_drive_pack(_PackFallible(), 10.0, 4.0), 2.5)
    with assert_raises(contains="division by zero"):
        _ = _drive_pack(_PackFallible(), 10.0, 0.0)


# =============================================================================
# FACT 3 — a NON-raising `def` binds to a `raises thin` comptime fn parameter.
# This is what lets `Map1`/`Map2`'s `f` widen with zero call-site edits, so it
# is NOT the expensive half. Pinned because the sugar's whole shape rests on it.
# =============================================================================
@fieldwise_init
struct _Adapter[
    T0: Copyable & Deinitable, O: DType, //, f: def(T0) raises thin -> Scalar[O]
](Copyable, Movable):
    def call(self, x: Self.T0) raises -> Scalar[Self.O]:
        return Self.f(x)


def _plain(a: Int64) -> Int64:  # no `raises` — every sugar UDF written so far
    return a * 10


def _fallible(a: Int64) raises -> Int64:
    if a == 0:
        raise Error("_fallible: zero")
    return 100 // a


def test_a_nonraising_def_binds_to_a_raising_fn_parameter() raises:
    assert_equal(_Adapter[f=_plain]().call(3), 30)
    assert_equal(_Adapter[f=_fallible]().call(4), 25)
    with assert_raises(contains="_fallible: zero"):
        _ = _Adapter[f=_fallible]().call(0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
