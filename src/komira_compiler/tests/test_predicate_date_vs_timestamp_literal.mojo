# =============================================================================
# test_predicate_date_vs_timestamp_literal.mojo
#   — a DATE literal against a TIMESTAMP (or DATE64) column, and a TIMESTAMP
#     literal against a DATE column, compare at MIDNIGHT like DuckDB — never
#     the raw day count against the column's ticks.
# =============================================================================
#
# ⛔ THE DEFECT (a SILENT WRONG ANSWER at every door that
# can send the pair: SQL, the untyped Mojo door). `_temporal_literal_i64`
# returned ONE threshold in the column's RAW TICKS from whichever field the
# literal filled: a date32 literal returned its DAY COUNT whatever the column,
# and a timestamp literal against a DATE32 column fell to the `else` and
# returned its MICROSECONDS. Through the SQL door:
# `n > DATE '2024-02-29'` kept 7 rows where DuckDB keeps 6;
# `d > TIMESTAMP '2024-12-30 06:07:08.009001'` kept 0 where DuckDB keeps 4.
#
# THE ORACLE is DuckDB v1.5.3, (refenv313) over EXACTLY the
# fixture below (k = 0..5):
#   n timestamp[us] = [2024-02-28 12:00, 2024-02-29 00:00, 2024-02-29 06:00,
#                      2024-03-01 00:00, 2023-01-01 00:00, NULL]
#     n >  DATE '2024-02-29'  -> k {2, 3}
#     n >= DATE '2024-02-29'  -> k {1, 2, 3}
#     n =  DATE '2024-02-29'  -> k {1}
#     n IN (DATE '2024-02-29') -> k {1}
#   d date32 = [2024-02-28, 2024-02-29, 2024-03-01, 2024-12-30, 2024-12-31, NULL]
#     d >  TIMESTAMP '2024-02-29 00:00:00' -> k {2, 3, 4}
#     d >= TIMESTAMP '2024-02-29 00:00:00' -> k {1, 2, 3, 4}
#     d >  TIMESTAMP '2024-02-29 06:00:00' -> k {2, 3, 4}   (served by DuckDB;
#       REFUSED BY NAME here -- an off-midnight threshold over a DATE needs the
#       operator adjusted, which this threshold cannot carry)
#
# ⚠ THE FIXTURE DISCRIMINATES. Under the old read, `n > <19782 days>` compared
#   19782 against microseconds and kept EVERY non-NULL row (5), and
#   `d > <micros>` kept NONE -- neither is DuckDB's answer, so each assertion
#   below is red on the unfixed kernel for a reason, not by coincidence.
#
# Encapsulation: NO UnsafePointer / wildcard origins.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import Expr, BIN_EQ, BIN_GE, BIN_GT
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_predicate import _eval_predicate


comptime _N: Int = 6
comptime _US_PER_S: Int64 = 1_000_000
comptime _US_PER_DAY: Int64 = 86_400_000_000
comptime _D_0229: Int32 = 19782  # 2024-02-29


def _secs() -> List[Int64]:
    """n's instants in SECONDS (row 5 is NULL)."""
    return [
        Int64(1709121600),  # 2024-02-28 12:00
        Int64(1709164800),  # 2024-02-29 00:00
        Int64(1709186400),  # 2024-02-29 06:00
        Int64(1709251200),  # 2024-03-01 00:00
        Int64(1672531200),  # 2023-01-01 00:00
        Int64(0),
    ]


def _ts_batch(at: ArrowType, ticks_per_s: Int64) raises -> RecordBatch:
    var s = _secs()
    var arr = PrimitiveArray[DType.int64].allocate_nullable(_N)
    for i in range(_N - 1):
        arr.set(i, s[i] * ticks_per_s)
    arr._set_null(_N - 1)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("n"), at, True))
    var rbb = RecordBatchBuilder.with_capacity(1)
    # The TAG goes on the COLUMN (`_eval_predicate` reads the column's own
    # arrow type; see test_predicate_literal_type_mismatch's `_ts_batch`).
    rbb.add_column(Column.from_primitive_with_arrow_type[DType.int64](arr^, at))
    return rbb.build(sb.build())


def _date_batch() raises -> RecordBatch:
    var days: List[Int32] = [19781, 19782, 19783, 20087, 20088, 0]
    var arr = PrimitiveArray[DType.int32].allocate_nullable(_N)
    for i in range(_N - 1):
        arr.set(i, days[i])
    arr._set_null(_N - 1)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("d"), ArrowType.DATE32, True))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](arr^, ArrowType.DATE32)
    )
    return rbb.build(sb.build())


def _rows(m: BooleanArray) raises -> String:
    """The selected row indexes, as "1,2,3"."""
    var out = String("")
    for i in range(m.length):
        if m.get(i):
            if out.byte_length() > 0:
                out += ","
            out += String(i)
    return out^


def _sel(batch: RecordBatch, name: String, op: UInt8, var v: ScalarValue) raises -> String:
    return _rows(
        _eval_predicate(
            Expr.binary(op, Expr.col_ref(name), Expr.literal(v^)), batch
        )
    )


# =============================================================================
# §1 — a DATE literal against a TIMESTAMP column, at EVERY unit.
# =============================================================================


def test_a_DATE_literal_vs_a_TIMESTAMP_column_compares_at_midnight() raises:
    var ats: List[ArrowType] = [
        ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_NS,
        ArrowType.TIMESTAMP_MS, ArrowType.TIMESTAMP_S,
    ]
    var tps: List[Int64] = [_US_PER_S, _US_PER_S * 1000, Int64(1000), Int64(1)]
    for i in range(len(ats)):
        var b = _ts_batch(ats[i], tps[i])
        var u = String(ats[i])
        assert_equal(
            _sel(b, String("n"), BIN_GT, ScalarValue.date32(_D_0229)),
            String("2,3"), u + ": n > DATE '2024-02-29'",
        )
        assert_equal(
            _sel(b, String("n"), BIN_GE, ScalarValue.date32(_D_0229)),
            String("1,2,3"), u + ": n >= DATE '2024-02-29'",
        )
        assert_equal(
            _sel(b, String("n"), BIN_EQ, ScalarValue.date32(_D_0229)),
            String("1"), u + ": n = DATE '2024-02-29'",
        )


def test_a_DATE_literal_in_an_IN_list_over_a_TIMESTAMP_column() raises:
    var b = _ts_batch(ArrowType.TIMESTAMP_US, _US_PER_S)
    var vals: List[ScalarValue] = [ScalarValue.date32(_D_0229)]
    assert_equal(
        _rows(_eval_predicate(Expr.in_list_node(Expr.col_ref(String("n")), vals^), b)),
        String("1"), "n IN (DATE '2024-02-29')",
    )


# =============================================================================
# §2 — a TIMESTAMP literal against a DATE column: served on a MIDNIGHT,
#      refused by name off it.
# =============================================================================


def test_a_midnight_TIMESTAMP_literal_vs_a_DATE_column_is_a_day_count() raises:
    var b = _date_batch()
    var mid = Int64(Int(_D_0229)) * _US_PER_DAY
    assert_equal(
        _sel(b, String("d"), BIN_GT, ScalarValue.timestamp_micros(mid)),
        String("2,3,4"), "d > TIMESTAMP '2024-02-29 00:00:00'",
    )
    assert_equal(
        _sel(b, String("d"), BIN_GE, ScalarValue.timestamp_micros(mid)),
        String("1,2,3,4"), "d >= TIMESTAMP '2024-02-29 00:00:00'",
    )


def test_an_off_midnight_TIMESTAMP_literal_vs_a_DATE_column_is_REFUSED() raises:
    var b = _date_batch()
    var six = Int64(Int(_D_0229)) * _US_PER_DAY + 6 * 3600 * _US_PER_S
    var raised = False
    var msg = String("")
    try:
        _ = _sel(b, String("d"), BIN_GT, ScalarValue.timestamp_micros(six))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "an off-midnight threshold over a DATE is refused")
    assert_true(
        "MIDNIGHT" in msg and "leftover microseconds" in msg,
        "refused BY NAME, saying why -- got: " + msg,
    )


# =============================================================================
# §3 — CONTROLS: the same-type pairs are unchanged.
# =============================================================================


def test_CONTROL_same_type_pairs_are_unchanged() raises:
    var b = _date_batch()
    assert_equal(
        _sel(b, String("d"), BIN_GT, ScalarValue.date32(_D_0229)),
        String("2,3,4"), "d > DATE '2024-02-29'",
    )
    var t = _ts_batch(ArrowType.TIMESTAMP_US, _US_PER_S)
    assert_equal(
        _sel(
            t, String("n"), BIN_GT,
            ScalarValue.timestamp_micros(Int64(1709164800) * _US_PER_S),
        ),
        String("2,3"), "n > TIMESTAMP '2024-02-29 00:00:00'",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
