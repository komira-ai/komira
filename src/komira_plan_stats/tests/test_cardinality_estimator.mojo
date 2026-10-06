"""The StatsProvider-driven estimators over the komira_collections sketch.

The sketch itself (`komira_collections.hyperloglog.HyperLogLog`: register
update, estimator, merge, accuracy) is tested in komira_collections. This file
covers, with a small in-memory `StatsProvider`:
  - `sketch_from_registers` / `registers_of`: a register list round-trips, and
    a list of the wrong length is not a sketch.
  - `estimate_groups`: no keys, no row groups, a missing signal, a product
    over several keys, and the clamp to the row count.
  - `build_table_stats_from_provider`: names, distinct and null counts,
    the provenance bit and the source tag.
  - `merge_table_stats`: empty input, a single source passed through, the
    MAX-of-NDV fallback (a source without registers, or with registers of the
    wrong length, or not flagged as sketched), and the register union: two
    disjoint halves merge to exactly the estimate and registers of the sketch
    of the whole, and a merged output merges again.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.hyperloglog import HLL_NUM_REGISTERS, HyperLogLog
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.cardinality_estimator import (
    build_table_stats_from_provider,
    estimate_groups,
    merge_table_stats,
    registers_of,
    sketch_from_registers,
)
from komira_plan_stats.physical_type import PhysicalType
from komira_plan_stats.stats_provider import StatsProvider
from komira_plan_stats.table_stats import (
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
    TableStats,
)


def _mix(x: UInt64) -> UInt64:
    """splitmix64 finalizer: a well-mixed 64-bit hash of a counter."""
    var z = x + UInt64(0x9E3779B97F4A7C15)
    z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> 31)


def _sketch_of(start: Int, count: Int) -> HyperLogLog:
    var h = HyperLogLog()
    for i in range(start, start + count):
        h.add_hash(_mix(UInt64(i)))
    return h^


def _within(estimate: Int, truth: Int, pct: Int) -> Bool:
    var diff = estimate - truth
    if diff < 0:
        diff = -diff
    return diff * 100 <= truth * pct


struct _StubProvider(StatsProvider):
    """Column `i` has NDV `ndvs[i]` (negative: no signal) and `nulls[i]`."""

    var rows: Int
    var row_groups: Int
    var names: List[String]
    var ndvs: List[Int]
    var nulls: List[Int]
    var hll_bits: List[Bool]
    var regs_a: Optional[List[UInt8]]

    def __init__(
        out self,
        rows: Int,
        row_groups: Int,
        var names: List[String],
        var ndvs: List[Int],
        var nulls: List[Int],
        var hll_bits: List[Bool],
        var regs_a: Optional[List[UInt8]] = None,
    ):
        self.rows = rows
        self.row_groups = row_groups
        self.names = names^
        self.ndvs = ndvs^
        self.nulls = nulls^
        self.hll_bits = hll_bits^
        self.regs_a = regs_a^

    def _find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def num_row_groups(self) -> Int:
        return self.row_groups

    def total_row_count(self) -> Int:
        return self.rows

    def column_physical_type(self, name: String) -> Optional[PhysicalType]:
        return None

    def column_rg_min_max(
        self, name: String, rg_idx: Int
    ) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        return None

    def column_min_max(
        self, name: String
    ) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        return None

    def column_distinct_count(self, name: String) -> Optional[Int]:
        return self.column_ndv_estimate(name)

    def column_null_count(self, name: String) -> Optional[Int]:
        var i = self._find(name)
        if i < 0:
            return None
        return Optional[Int](self.nulls[i])

    def column_ndv_estimate(self, name: String) -> Optional[Int]:
        var i = self._find(name)
        if i < 0 or self.ndvs[i] < 0:
            return None
        return Optional[Int](self.ndvs[i])

    def column_ndv_estimate_from_hll(self, name: String) -> Bool:
        var i = self._find(name)
        if i < 0:
            return False
        return self.hll_bits[i]

    def column_merged_hll_registers(self, name: String) -> Optional[List[UInt8]]:
        if name == "a":
            return self.regs_a.copy()
        return None


def _provider(
    rows: Int, row_groups: Int, ndv_a: Int, ndv_b: Int
) -> _StubProvider:
    var names = List[String]()
    names.append("a")
    names.append("b")
    var ndvs = List[Int]()
    ndvs.append(ndv_a)
    ndvs.append(ndv_b)
    var nulls = List[Int]()
    nulls.append(3)
    nulls.append(0)
    var bits = List[Bool]()
    bits.append(False)
    bits.append(False)
    return _StubProvider(rows, row_groups, names^, ndvs^, nulls^, bits^)


def _keys(a: String, b: String = "") -> List[String]:
    var k = List[String]()
    k.append(a)
    if b != "":
        k.append(b)
    return k^


def test_registers_round_trip() raises:
    var h = _sketch_of(0, 5000)
    var regs = registers_of(h)
    assert_equal(len(regs), HLL_NUM_REGISTERS)
    var back = sketch_from_registers(regs)
    assert_true(Bool(back))
    for i in range(HLL_NUM_REGISTERS):
        assert_equal(back.value().register(i), h.register(i))
    assert_equal(back.value().estimate(), h.estimate())
    # An empty register list of the right length is the empty sketch.
    assert_equal(registers_of(HyperLogLog())[7], UInt8(0))


def test_sketch_from_registers_rejects_wrong_length() raises:
    assert_false(Bool(sketch_from_registers(List[UInt8]())))
    var short = registers_of(_sketch_of(0, 100))
    _ = short.pop()
    assert_false(Bool(sketch_from_registers(short)))
    var long = registers_of(_sketch_of(0, 100))
    long.append(UInt8(1))
    assert_false(Bool(sketch_from_registers(long)))


def test_estimate_groups_edges() raises:
    # No GROUP BY keys: one group.
    var one = estimate_groups(_provider(1000, 2, 10, 20), List[String]())
    assert_equal(one.value(), 1)
    # No row groups: no estimate.
    assert_false(Bool(estimate_groups(_provider(1000, 0, 10, 20), _keys("a"))))
    # Empty table: no estimate.
    assert_false(Bool(estimate_groups(_provider(0, 1, 10, 20), _keys("a"))))
    # A key with no distinct-count signal: no estimate.
    assert_false(
        Bool(estimate_groups(_provider(1000, 2, 10, -1), _keys("a", "b")))
    )
    # An unknown key: no estimate.
    assert_false(Bool(estimate_groups(_provider(1000, 2, 10, 20), _keys("zz"))))


def test_estimate_groups_product_and_clamp() raises:
    var single = estimate_groups(_provider(1000, 2, 10, 20), _keys("a"))
    assert_equal(single.value(), 10)
    # Several keys multiply (independence assumption).
    var both = estimate_groups(_provider(1000, 2, 10, 20), _keys("a", "b"))
    assert_equal(both.value(), 200)
    # The product is clamped to the row count.
    var clamped = estimate_groups(_provider(150, 2, 10, 20), _keys("a", "b"))
    assert_equal(clamped.value(), 150)


def _schema_ab() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", DType.int64, True))
    sb.add_field(Field("b", DType.int64, True))
    return sb.build()


def test_build_table_stats_from_provider() raises:
    var ts = build_table_stats_from_provider(
        _provider(1000, 2, 10, 20), _schema_ab()
    )
    assert_equal(ts.row_count, 1000)
    assert_equal(len(ts.column_names), 2)
    assert_equal(ts.column_names[0], "a")
    assert_equal(ts.column_names[1], "b")
    assert_equal(ts.source, STATS_SOURCE_PARQUET_METADATA)
    assert_equal(ts.column_distinct_count("a").value(), 10)
    assert_equal(ts.column_distinct_count("b").value(), 20)
    assert_equal(ts.column_stats[0].null_count.value(), 3)
    assert_false(ts.column_distinct_count_from_hll("a"))
    # A provider without the sketch bit hands over no registers.
    assert_false(Bool(ts.column_stats[0].hll_registers))


def test_build_table_stats_carries_registers_when_sketched() raises:
    var names = List[String]()
    names.append("a")
    names.append("b")
    var ndvs = List[Int]()
    ndvs.append(4000)
    ndvs.append(20)
    var nulls = List[Int]()
    nulls.append(0)
    nulls.append(0)
    var bits = List[Bool]()
    bits.append(True)
    bits.append(False)
    var sketch = _sketch_of(0, 4000)
    var p = _StubProvider(
        5000, 2, names^, ndvs^, nulls^, bits^,
        Optional[List[UInt8]](registers_of(sketch)),
    )
    var ts = build_table_stats_from_provider(p, _schema_ab())
    assert_true(ts.column_distinct_count_from_hll("a"))
    assert_false(ts.column_distinct_count_from_hll("b"))
    ref regs = ts.column_stats[0].hll_registers.value()
    assert_equal(len(regs), HLL_NUM_REGISTERS)
    for i in range(HLL_NUM_REGISTERS):
        assert_equal(regs[i], sketch.register(i))
    assert_false(Bool(ts.column_stats[1].hll_registers))


def _stats_with(
    rows: Int, ndv: Int, var regs: Optional[List[UInt8]], from_hll: Bool
) -> TableStats:
    var names = List[String]()
    names.append("k")
    var cols = List[ColumnStats]()
    cols.append(ColumnStats(Optional[Int](ndv), None, None, Optional[Int](1), regs^))
    var bits = List[Bool]()
    bits.append(from_hll)
    return TableStats(
        rows, names^, cols^, STATS_SOURCE_PARQUET_METADATA, bits^
    )


def test_merge_table_stats_trivial_cases() raises:
    var none = merge_table_stats(List[TableStats]())
    assert_equal(none.row_count, 0)
    assert_equal(len(none.column_names), 0)
    var only = List[TableStats]()
    only.append(_stats_with(100, 7, None, False))
    var passed = merge_table_stats(only)
    assert_equal(passed.row_count, 100)
    assert_equal(passed.column_distinct_count("k").value(), 7)


def test_merge_table_stats_fallback_is_max_of_ndv() raises:
    var list = List[TableStats]()
    list.append(_stats_with(100, 7, None, False))
    list.append(_stats_with(300, 11, None, False))
    var m = merge_table_stats(list)
    assert_equal(m.row_count, 400)
    assert_equal(m.column_distinct_count("k").value(), 11)
    assert_false(m.column_distinct_count_from_hll("k"))
    # Null counts add across sources.
    assert_equal(m.column_stats[0].null_count.value(), 2)


def _sketched(rows: Int, sketch: HyperLogLog) -> TableStats:
    return _stats_with(
        rows,
        sketch.estimate(),
        Optional[List[UInt8]](registers_of(sketch)),
        True,
    )


def test_merge_table_stats_registers_union_disjoint_sources() raises:
    var list = List[TableStats]()
    list.append(_sketched(10000, _sketch_of(0, 10000)))
    list.append(_sketched(10000, _sketch_of(10000, 10000)))
    var m = merge_table_stats(list)
    var whole = _sketch_of(0, 20000)
    # MAX-of-NDV would say ~10000; the union of the registers is exactly the
    # sketch of all 20000 values, so its estimate is that sketch's estimate.
    assert_true(m.column_distinct_count_from_hll("k"))
    assert_equal(m.column_distinct_count("k").value(), whole.estimate())
    assert_true(_within(m.column_distinct_count("k").value(), 20000, 6))
    ref regs = m.column_stats[0].hll_registers.value()
    for i in range(HLL_NUM_REGISTERS):
        assert_equal(regs[i], whole.register(i))


def test_merge_table_stats_output_merges_again() raises:
    var first = List[TableStats]()
    first.append(_sketched(10000, _sketch_of(0, 10000)))
    first.append(_sketched(10000, _sketch_of(10000, 10000)))
    var second = List[TableStats]()
    second.append(merge_table_stats(first))
    second.append(_sketched(10000, _sketch_of(20000, 10000)))
    var m = merge_table_stats(second)
    assert_equal(m.row_count, 30000)
    assert_equal(
        m.column_distinct_count("k").value(), _sketch_of(0, 30000).estimate()
    )


def test_merge_table_stats_falls_back_without_a_full_sketch() raises:
    var s1 = _sketch_of(0, 10000)
    var s2 = _sketch_of(10000, 10000)
    # One source has no registers: MAX-of-NDV, not a sketch union.
    var missing = List[TableStats]()
    missing.append(_sketched(10000, s1))
    missing.append(_stats_with(10000, 9000, None, False))
    var m1 = merge_table_stats(missing)
    assert_false(m1.column_distinct_count_from_hll("k"))
    assert_equal(m1.column_distinct_count("k").value(), max(s1.estimate(), 9000))
    assert_false(Bool(m1.column_stats[0].hll_registers))
    # One source's registers have the wrong length.
    var bad = registers_of(s2)
    _ = bad.pop()
    var short = List[TableStats]()
    short.append(_sketched(10000, s1))
    short.append(_stats_with(10000, s2.estimate(), Optional[List[UInt8]](bad^), True))
    var m2 = merge_table_stats(short)
    assert_false(m2.column_distinct_count_from_hll("k"))
    assert_equal(
        m2.column_distinct_count("k").value(), max(s1.estimate(), s2.estimate())
    )
    # Registers present but the source is not flagged as sketched.
    var unflagged = List[TableStats]()
    unflagged.append(_sketched(10000, s1))
    unflagged.append(
        _stats_with(10000, s2.estimate(), Optional[List[UInt8]](registers_of(s2)), False)
    )
    var m3 = merge_table_stats(unflagged)
    assert_false(m3.column_distinct_count_from_hll("k"))


def main() raises:
    test_registers_round_trip()
    test_sketch_from_registers_rejects_wrong_length()
    test_estimate_groups_edges()
    test_estimate_groups_product_and_clamp()
    test_build_table_stats_from_provider()
    test_build_table_stats_carries_registers_when_sketched()
    test_merge_table_stats_trivial_cases()
    test_merge_table_stats_fallback_is_max_of_ndv()
    test_merge_table_stats_registers_union_disjoint_sources()
    test_merge_table_stats_output_merges_again()
    test_merge_table_stats_falls_back_without_a_full_sketch()
    print("all cardinality estimator tests passed")
