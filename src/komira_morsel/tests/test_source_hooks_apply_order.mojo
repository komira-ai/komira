# =============================================================================
# LoweredSourceHooks + apply_source_hooks: payload defaults, setters, and the
# documented hook order; MorselSourceImpl's default methods.
# =============================================================================
#
# What these tests prove (oracles from the docstrings of `source_hooks.mojo`
# and `morsel_source.mojo`, worked out by hand):
#
#   * An empty `LoweredSourceHooks` is "no hook" in every field, and each
#     setter fills exactly its own field (a copy taken before is unchanged).
#   * `apply_source_hooks` calls the source's setters in the order of the
#     docstring: expr_pool, cancel flag, projection, bypass columns, pushed
#     predicate, dict preservation, decode filter, morsel rows, prefetch,
#     count-only, dynamic filter; and it forwards the very values and
#     pointers the payload carries.
#   * A setter is skipped when its field is in the "no hook" state (an empty
#     list, `None`, `False`, `morsel_rows <= 0`), except dict preservation,
#     which is forwarded every time (also when False).
#   * A source with `HOOKS_CONSUMED_AT_CONSTRUCTION = True` gets no setter
#     call at all.
#   * A source that overrides none of the optional trait methods gets the
#     trait defaults: empty statistics, `has_decode_filter() == False`, and
#     setters that accept every hook without raising.
#
# Single-threaded: hooks run once before the first `next_morsel`, by contract.
# =============================================================================

from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_atomic_alias import AtomicI8
from komira_arrow.schema import Schema
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl, SourceCapabilities
from komira_morsel.source_hooks import LoweredSourceHooks, apply_source_hooks
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool


def _ints(xs: List[Int]) -> String:
    var s = String("[")
    for i in range(len(xs)):
        if i > 0:
            s += ","
        s += String(xs[i])
    return s + "]"


def _ids(xs: List[ExprId]) -> String:
    var s = String("[")
    for i in range(len(xs)):
        if i > 0:
            s += ","
        s += String(xs[i].id)
    return s + "]"


def _df(keys: List[Int64]) -> DynamicJoinFilter:
    var o = DynamicJoinFilter.build_int64_from_list(keys)
    return o.take()


struct RecordingSource(MorselSourceImpl):
    """Overrides every hook setter and logs each call, in call order, with
    the value it was given (pointers as their address)."""

    var log: List[String]

    def __init__(out self):
        self.log = List[String]()

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        return None

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return 1

    def row_count_hint(self) -> Int:
        return 0

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()

    def set_cancel_flag[
        origin: Origin[mut=True]
    ](mut self, flag: UnsafePointer[AtomicI8, origin],) -> None:
        self.log.append("cancel@" + String(Int(flag)))

    def set_projection(mut self, cols: List[Int]) -> None:
        self.log.append("projection" + _ints(cols))

    def set_decode_filter(mut self, stages: List[ExprId]) -> None:
        self.log.append("decode" + _ids(stages))

    def set_pushed_predicate(mut self, expr: ExprId) -> None:
        self.log.append("pred" + String(expr.id))

    def set_bypass_columns(mut self, cols: List[Int]) -> None:
        self.log.append("bypass" + _ints(cols))

    def set_dict_preservation(mut self, on: Bool) -> None:
        self.log.append("dict" + String(on))

    def set_expr_pool[
        origin: Origin[mut=True]
    ](mut self, pool: UnsafePointer[ExprPool, origin],) -> None:
        self.log.append("pool@" + String(Int(pool)))

    def set_morsel_rows(mut self, rows: Int) -> None:
        self.log.append("rows" + String(rows))

    def set_prefetch_enabled(mut self, on: Bool) -> None:
        self.log.append("prefetch" + String(on))

    def set_count_only(mut self, on: Bool) -> None:
        self.log.append("count_only" + String(on))

    def set_dynamic_filter[
        origin: Origin[mut=True]
    ](
        mut self,
        df: UnsafePointer[DynamicJoinFilter, origin],
        key_name: String,
    ) -> None:
        self.log.append("dyn@" + String(Int(df)) + ":" + key_name)


struct ConstructionTimeSource(MorselSourceImpl):
    """Declares HOOKS_CONSUMED_AT_CONSTRUCTION; logs any setter it gets."""

    comptime HOOKS_CONSUMED_AT_CONSTRUCTION: Bool = True
    var log: List[String]

    def __init__(out self):
        self.log = List[String]()

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        return None

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return 1

    def row_count_hint(self) -> Int:
        return 0

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()

    def set_projection(mut self, cols: List[Int]) -> None:
        self.log.append("projection")

    def set_dict_preservation(mut self, on: Bool) -> None:
        self.log.append("dict")

    def set_morsel_rows(mut self, rows: Int) -> None:
        self.log.append("rows")


struct DefaultsSource(MorselSourceImpl):
    """Implements only the required methods: every optional one is the
    trait default."""

    var n: Int

    def __init__(out self):
        self.n = 0

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        return None

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return 1

    def row_count_hint(self) -> Int:
        return 0

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()


def _expect_log(got: List[String], want: List[String], what: String) raises:
    var g = String(" | ").join(got)
    var w = String(" | ").join(want)
    assert_equal(g, w, what)


def test_empty_payload_is_no_hook() raises:
    var h = LoweredSourceHooks()
    assert_equal(len(h.projection), 0)
    assert_equal(len(h.decode_filter), 0)
    assert_false(Bool(h.pushed_predicate))
    assert_equal(len(h.bypass_columns), 0)
    assert_false(h.dict_preservation)
    assert_false(Bool(h.cancel_flag_ptr))
    assert_false(Bool(h.expr_pool))
    assert_equal(h.morsel_rows, 0)
    assert_false(h.prefetch_enabled)
    assert_false(h.count_only)
    assert_false(Bool(h.dynamic_filter_ptr))
    assert_equal(h.dynamic_filter_key_name, "")
    assert_false(Bool(h.hash_agg_key_col_idx))
    assert_false(Bool(h.hash_agg_agg_col_indices))
    # `default()` is the same empty payload.
    var d = LoweredSourceHooks.default()
    assert_equal(d.morsel_rows, 0)
    assert_false(d.dict_preservation)
    assert_false(Bool(d.expr_pool))
    assert_equal(len(d.projection), 0)


def test_setters_fill_their_own_field() raises:
    var flag = AtomicI8(Int8(0))
    var pool = ExprPool()
    var df = _df([Int64(3), Int64(5)])
    var h = LoweredSourceHooks()
    var before = h.copy()
    h.set_projection([2, 0, 5])
    h.set_decode_filter([ExprId(id=4), ExprId(id=9)])
    h.set_pushed_predicate(ExprId(id=11))
    h.set_bypass_columns([1, 3])
    h.set_dict_preservation(True)
    h.set_cancel_flag(UnsafePointer(to=flag))
    h.set_expr_pool(UnsafePointer(to=pool))
    h.set_morsel_rows(8192)
    h.set_prefetch_enabled(True)
    h.set_count_only(True)
    h.set_dynamic_filter(UnsafePointer(to=df), "o_custkey")
    h.set_hash_agg_decode_fused(6, [1, 4, 2])

    assert_equal(_ints(h.projection), "[2,0,5]")
    assert_equal(_ids(h.decode_filter), "[4,9]")
    assert_equal(Int(h.pushed_predicate.value().id), 11)
    assert_equal(_ints(h.bypass_columns), "[1,3]")
    assert_true(h.dict_preservation)
    assert_equal(Int(h.cancel_flag_ptr.value()), Int(UnsafePointer(to=flag)))
    assert_equal(Int(h.expr_pool.value()), Int(UnsafePointer(to=pool)))
    assert_equal(h.morsel_rows, 8192)
    assert_true(h.prefetch_enabled)
    assert_true(h.count_only)
    assert_equal(Int(h.dynamic_filter_ptr.value()), Int(UnsafePointer(to=df)))
    assert_equal(h.dynamic_filter_key_name, "o_custkey")
    assert_equal(h.hash_agg_key_col_idx.value(), 6)
    # Order of the agg-input columns is preserved (docstring contract).
    assert_equal(_ints(h.hash_agg_agg_col_indices.value()), "[1,4,2]")

    # The copy taken before the setters is still empty: Copyable is a value
    # copy, not a shared payload.
    assert_equal(len(before.projection), 0)
    assert_false(Bool(before.expr_pool))
    assert_equal(before.morsel_rows, 0)
    _ = flag.load()
    _ = len(pool)
    _ = df.has_bloom()


def test_full_payload_applies_in_documented_order() raises:
    var flag = AtomicI8(Int8(0))
    var pool = ExprPool()
    var df = _df([Int64(7)])
    var flag_at = String(Int(UnsafePointer(to=flag)))
    var pool_at = String(Int(UnsafePointer(to=pool)))
    var df_at = String(Int(UnsafePointer(to=df)))

    var h = LoweredSourceHooks()
    # Set in an order unlike the apply order, so the log order can only come
    # from `apply_source_hooks`.
    h.set_dynamic_filter(UnsafePointer(to=df), "k")
    h.set_count_only(True)
    h.set_prefetch_enabled(True)
    h.set_morsel_rows(4096)
    h.set_decode_filter([ExprId(id=2), ExprId(id=3)])
    h.set_dict_preservation(True)
    h.set_pushed_predicate(ExprId(id=1))
    h.set_bypass_columns([4])
    h.set_projection([0, 2])
    h.set_cancel_flag(UnsafePointer(to=flag))
    h.set_expr_pool(UnsafePointer(to=pool))

    var src = RecordingSource()
    apply_source_hooks(src, h)
    _expect_log(
        src.log,
        [
            "pool@" + pool_at,
            "cancel@" + flag_at,
            "projection[0,2]",
            "bypass[4]",
            "pred1",
            "dictTrue",
            "decode[2,3]",
            "rows4096",
            "prefetchTrue",
            "count_onlyTrue",
            "dyn@" + df_at + ":k",
        ],
        "full payload apply order",
    )
    # `hooks` is borrowed, not consumed: applying again gives the same log.
    var src2 = RecordingSource()
    apply_source_hooks(src2, h)
    assert_equal(len(src2.log), 11)
    _ = flag.load()
    _ = len(pool)
    _ = df.has_bloom()


def test_empty_payload_forwards_only_dict_preservation() raises:
    var src = RecordingSource()
    apply_source_hooks(src, LoweredSourceHooks())
    _expect_log(src.log, ["dictFalse"], "empty payload")


def test_each_hook_alone() raises:
    # One field set at a time: exactly that setter (plus the always-forwarded
    # dict flag, in its fixed place) is called.
    var flag = AtomicI8(Int8(0))
    var pool = ExprPool()
    var df = _df([Int64(1)])

    var h1 = LoweredSourceHooks()
    h1.set_expr_pool(UnsafePointer(to=pool))
    var s1 = RecordingSource()
    apply_source_hooks(s1, h1)
    _expect_log(
        s1.log,
        ["pool@" + String(Int(UnsafePointer(to=pool))), "dictFalse"],
        "pool only",
    )

    var h2 = LoweredSourceHooks()
    h2.set_cancel_flag(UnsafePointer(to=flag))
    var s2 = RecordingSource()
    apply_source_hooks(s2, h2)
    _expect_log(
        s2.log,
        ["cancel@" + String(Int(UnsafePointer(to=flag))), "dictFalse"],
        "cancel only",
    )

    var h3 = LoweredSourceHooks()
    h3.set_projection([7])
    var s3 = RecordingSource()
    apply_source_hooks(s3, h3)
    _expect_log(s3.log, ["projection[7]", "dictFalse"], "projection only")

    var h4 = LoweredSourceHooks()
    h4.set_bypass_columns([0, 1, 2])
    var s4 = RecordingSource()
    apply_source_hooks(s4, h4)
    _expect_log(s4.log, ["bypass[0,1,2]", "dictFalse"], "bypass only")

    var h5 = LoweredSourceHooks()
    # ExprId 0 is a real handle: presence is the Optional, not a non-zero id.
    h5.set_pushed_predicate(ExprId(id=0))
    var s5 = RecordingSource()
    apply_source_hooks(s5, h5)
    _expect_log(s5.log, ["pred0", "dictFalse"], "predicate only")

    var h6 = LoweredSourceHooks()
    h6.set_decode_filter([ExprId(id=5)])
    var s6 = RecordingSource()
    apply_source_hooks(s6, h6)
    _expect_log(s6.log, ["dictFalse", "decode[5]"], "decode only")

    var h7 = LoweredSourceHooks()
    h7.set_prefetch_enabled(True)
    var s7 = RecordingSource()
    apply_source_hooks(s7, h7)
    _expect_log(s7.log, ["dictFalse", "prefetchTrue"], "prefetch only")

    var h8 = LoweredSourceHooks()
    h8.set_count_only(True)
    var s8 = RecordingSource()
    apply_source_hooks(s8, h8)
    _expect_log(s8.log, ["dictFalse", "count_onlyTrue"], "count-only only")

    var h9 = LoweredSourceHooks()
    h9.set_dynamic_filter(UnsafePointer(to=df), "id")
    var s9 = RecordingSource()
    apply_source_hooks(s9, h9)
    _expect_log(
        s9.log,
        ["dictFalse", "dyn@" + String(Int(UnsafePointer(to=df))) + ":id"],
        "dynamic filter only",
    )
    _ = flag.load()
    _ = len(pool)
    _ = df.has_bloom()


def test_morsel_rows_boundary() raises:
    # `morsel_rows > 0` is forwarded; 0 (disabled) and a negative value are not.
    var h1 = LoweredSourceHooks()
    h1.set_morsel_rows(1)
    var s1 = RecordingSource()
    apply_source_hooks(s1, h1)
    _expect_log(s1.log, ["dictFalse", "rows1"], "morsel_rows 1")

    var h0 = LoweredSourceHooks()
    h0.set_morsel_rows(0)
    var s0 = RecordingSource()
    apply_source_hooks(s0, h0)
    _expect_log(s0.log, ["dictFalse"], "morsel_rows 0")

    var hn = LoweredSourceHooks()
    hn.set_morsel_rows(-1)
    var sn = RecordingSource()
    apply_source_hooks(sn, hn)
    _expect_log(sn.log, ["dictFalse"], "morsel_rows -1")


def test_false_flags_are_not_forwarded_but_dict_false_is() raises:
    # Setting a flag back to False is the "no hook" state again.
    var h = LoweredSourceHooks()
    h.set_prefetch_enabled(True)
    h.set_prefetch_enabled(False)
    h.set_count_only(True)
    h.set_count_only(False)
    h.set_dict_preservation(True)
    h.set_dict_preservation(False)
    var s = RecordingSource()
    apply_source_hooks(s, h)
    _expect_log(s.log, ["dictFalse"], "flags reset to False")


def test_construction_time_source_gets_no_setter() raises:
    var h = LoweredSourceHooks()
    h.set_projection([1])
    h.set_dict_preservation(True)
    h.set_morsel_rows(64)
    var src = ConstructionTimeSource()
    apply_source_hooks(src, h)
    assert_equal(len(src.log), 0, "construction-time source got a setter call")


def test_trait_defaults() raises:
    var flag = AtomicI8(Int8(0))
    var pool = ExprPool()
    var df = _df([Int64(2)])
    var src = DefaultsSource()
    var st = src.statistics()
    assert_false(Bool(st.num_rows))
    assert_false(Bool(st.total_byte_size))
    assert_equal(len(st.per_column), 0)
    assert_false(src.has_decode_filter())
    # Every optional setter is a no-op default: driving them all (directly
    # and through the applier) raises nothing and changes nothing visible.
    src.set_cancel_flag(UnsafePointer(to=flag))
    src.set_projection([0])
    src.set_decode_filter([ExprId(id=1)])
    src.set_pushed_predicate(ExprId(id=2))
    src.set_bypass_columns([0])
    src.set_dict_preservation(True)
    src.set_expr_pool(UnsafePointer(to=pool))
    src.set_morsel_rows(10)
    src.set_prefetch_enabled(True)
    src.set_count_only(True)
    src.set_dynamic_filter(UnsafePointer(to=df), "k")
    var h = LoweredSourceHooks()
    h.set_expr_pool(UnsafePointer(to=pool))
    h.set_cancel_flag(UnsafePointer(to=flag))
    h.set_projection([0])
    h.set_bypass_columns([0])
    h.set_pushed_predicate(ExprId(id=2))
    h.set_decode_filter([ExprId(id=1)])
    h.set_morsel_rows(10)
    h.set_prefetch_enabled(True)
    h.set_count_only(True)
    h.set_dynamic_filter(UnsafePointer(to=df), "k")
    apply_source_hooks(src, h)
    assert_false(src.has_decode_filter())
    assert_equal(flag.load(), Int8(0))
    assert_equal(src.n, 0)
    _ = len(pool)
    _ = df.has_bloom()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
