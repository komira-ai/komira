# =============================================================================
# test_search_scan_pushdown_gate.mojo: the fast-field pushdown gate admits a
# temporal literal only when the field stores values in the literal's unit.
# =============================================================================
#
# SearchCore evaluates a pushed conjunct by comparing the literal's raw value
# (DATE32 days, TIMESTAMP microseconds) with the raw stored cell. A conjunct
# the gate accepts is applied inside the scan, and a row it drops cannot come
# back from the filter above the scan. So for every conjunct below:
#   * if the gate accepts it, the pushed answer must be the DuckDB answer;
#   * a cross-unit literal must be refused (the engine filter evaluates it).
#
#   1. TIMESTAMP(us) field, values 1us and 2us: `ts < DATE 1970-01-02` keeps
#      both rows in DuckDB. Before the fix the gate accepted it and the scan
#      compared 1 and 2 with 1 (days): 0 rows (komira-ai/komira#1511).
#   2. DATE32 field, days 19000 and 19001: `day > TIMESTAMP 1970-01-02`
#      (86400000000us) keeps both rows. Before the fix: 0 rows.
#   3. TIMESTAMP_MS field, 1ms and 2ms: `ms < TIMESTAMP 1500us` keeps one row;
#      a raw compare keeps two. DATE64 against a DATE literal likewise.
#   4. Same-unit controls stay pushed and give the DuckDB answer: TIMESTAMP and
#      TIMESTAMP_US against a TIMESTAMP literal, DATE32 against a DATE literal,
#      and an int literal against a DATE32 field (raw days, unchanged).
#   5. An INT64 numeric field refuses DATE and TIMESTAMP literals; an IN list
#      with one cross-unit value is refused.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_LT,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_search.analyzer import (
    AnalyzedField,
    AnalyzerConfig,
    Token,
    FIELD_CLASS_DATE,
    FIELD_CLASS_NUMERIC,
)
from komira_search.fast_fields import (
    FastFieldSpec,
    NumericFastFieldBuilder,
    KeywordFastFieldBuilder,
    serialize_fastfields_region,
)
from komira_search.inverted import InvertedIndexBuilder
from komira_search.split import serialize_split, DocStoreBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.source import QueryIR, SearchCore
from komira_search_scan.search_source import FastFieldPushdownGate


comptime _REFUSED = -1


def _uuid() -> Array[UInt8, 16]:
    return Array[UInt8, 16](fill=7)


def _spec(name: String, cls: UInt8, at: ArrowType, dt: DType) -> FastFieldSpec:
    return FastFieldSpec(name, 0, cls, at.type_id, dt)


def _col(at: ArrowType, dt: DType, a: Int, b: Int) -> NumericFastFieldBuilder:
    var nb = NumericFastFieldBuilder(at.type_id, dt)
    nb.append_int(a, False)
    nb.append_int(b, False)
    return nb^


def _two_doc_split() raises -> List[UInt8]:
    """Two docs, each the one term "w" in `body`, with these fast fields:
    ts TIMESTAMP {1, 2}, tsu TIMESTAMP_US {1, 2}, day DATE32 {19000, 19001},
    ms TIMESTAMP_MS {1, 2}, d64 DATE64 {1, 2}, n INT64 {1, 2}."""
    var specs = List[FastFieldSpec]()
    var nums = List[NumericFastFieldBuilder]()
    specs.append(_spec("ts", FIELD_CLASS_DATE, ArrowType.TIMESTAMP, DType.int64))
    nums.append(_col(ArrowType.TIMESTAMP, DType.int64, 1, 2))
    specs.append(
        _spec("tsu", FIELD_CLASS_DATE, ArrowType.TIMESTAMP_US, DType.int64)
    )
    nums.append(_col(ArrowType.TIMESTAMP_US, DType.int64, 1, 2))
    specs.append(_spec("day", FIELD_CLASS_DATE, ArrowType.DATE32, DType.int32))
    nums.append(_col(ArrowType.DATE32, DType.int32, 19000, 19001))
    specs.append(
        _spec("ms", FIELD_CLASS_DATE, ArrowType.TIMESTAMP_MS, DType.int64)
    )
    nums.append(_col(ArrowType.TIMESTAMP_MS, DType.int64, 1, 2))
    specs.append(_spec("d64", FIELD_CLASS_DATE, ArrowType.DATE64, DType.int64))
    nums.append(_col(ArrowType.DATE64, DType.int64, 1, 2))
    specs.append(_spec("n", FIELD_CLASS_NUMERIC, ArrowType.INT64, DType.int64))
    nums.append(_col(ArrowType.INT64, DType.int64, 1, 2))
    var ff = serialize_fastfields_region(
        specs, nums, List[KeywordFastFieldBuilder](),
        _col(ArrowType.INT64, DType.int64, 1, 1),
    )

    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder(compress=False)
    for d in range(2):
        var toks = List[Token]()
        toks.append(Token(String("w"), 0))
        b.add_document(d, AnalyzedField(toks^))
        ds.append(String("d").as_bytes())
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    return serialize_split(
        fi, td^, ds, String("body"), _uuid(), 0, 1, 2, fastfields_region=ff^
    )


def _cmp(op: UInt8, col: String, var lit: ScalarValue) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(lit^))


def _pushed_rows(bytes: List[UInt8], pred: Expr) raises -> Int:
    """The rows the scan keeps when `pred` is pushed, or _REFUSED when the gate
    keeps it above the scan."""
    var gate = FastFieldPushdownGate.from_split_bytes(bytes)
    if not gate.supports_filter_pushdown(pred):
        return _REFUSED
    var core = SearchCore(bytes.copy())
    var q = QueryIR(
        String("body"), String("w"), 10, AnalyzerConfig.text("body"), 0,
        Optional[Expr](pred.copy()),
    )
    return core.search(q).total_matches


def _assert_pushed_answer_or_refused(
    bytes: List[UInt8], pred: Expr, duckdb_rows: Int, what: String
) raises:
    """The contract: a conjunct the gate accepts gives the DuckDB answer."""
    var got = _pushed_rows(bytes, pred)
    if got != _REFUSED:
        assert_equal(got, duckdb_rows, what + ": pushed answer != DuckDB")


def test_01_timestamp_field_against_date_literal() raises:
    var bytes = _two_doc_split()
    # 1us and 2us are both before 1970-01-02.
    var pred = _cmp(BIN_LT, "ts", ScalarValue.date32(1))
    _assert_pushed_answer_or_refused(bytes, pred, 2, "ts < DATE 1970-01-02")
    assert_equal(_pushed_rows(bytes, pred), _REFUSED, "ts < DATE is refused")
    var pred_us = _cmp(BIN_LT, "tsu", ScalarValue.date32(1))
    _assert_pushed_answer_or_refused(bytes, pred_us, 2, "tsu < DATE")
    assert_equal(_pushed_rows(bytes, pred_us), _REFUSED, "tsu < DATE refused")


def test_02_date_field_against_timestamp_literal() raises:
    var bytes = _two_doc_split()
    # 2022-01-08 and 2022-01-09 are both after 1970-01-02 00:00:00.
    var pred = _cmp(BIN_GT, "day", ScalarValue.timestamp_micros(86400000000))
    _assert_pushed_answer_or_refused(bytes, pred, 2, "day > TIMESTAMP")
    assert_equal(_pushed_rows(bytes, pred), _REFUSED, "day > TIMESTAMP refused")


def test_03_other_units_refuse_temporal_literals() raises:
    var bytes = _two_doc_split()
    # 1ms = 1000us < 1500us; 2ms = 2000us is not.
    var pred = _cmp(BIN_LT, "ms", ScalarValue.timestamp_micros(1500))
    _assert_pushed_answer_or_refused(bytes, pred, 1, "ms < TIMESTAMP 1500us")
    assert_equal(_pushed_rows(bytes, pred), _REFUSED, "ms < TIMESTAMP refused")
    # DATE64 1ms and 2ms are both before 1970-01-02.
    var pred_d = _cmp(BIN_LT, "d64", ScalarValue.date32(1))
    _assert_pushed_answer_or_refused(bytes, pred_d, 2, "d64 < DATE")
    assert_equal(_pushed_rows(bytes, pred_d), _REFUSED, "d64 < DATE refused")


def test_04_same_unit_literals_stay_pushed() raises:
    var bytes = _two_doc_split()
    assert_equal(
        _pushed_rows(bytes, _cmp(BIN_LT, "ts", ScalarValue.timestamp_micros(3))),
        2, "ts < TIMESTAMP 3us",
    )
    assert_equal(
        _pushed_rows(bytes, _cmp(BIN_GE, "tsu", ScalarValue.timestamp_micros(2))),
        1, "tsu >= TIMESTAMP 2us",
    )
    assert_equal(
        _pushed_rows(bytes, _cmp(BIN_GT, "day", ScalarValue.date32(19000))),
        1, "day > DATE 19000",
    )
    assert_equal(
        _pushed_rows(bytes, _cmp(BIN_EQ, "day", ScalarValue.from_int(19001))),
        1, "day = 19001 (int literal, raw days)",
    )


def test_05_numeric_field_and_in_list_refuse_cross_unit() raises:
    var bytes = _two_doc_split()
    assert_equal(
        _pushed_rows(bytes, _cmp(BIN_EQ, "n", ScalarValue.date32(1))),
        _REFUSED, "INT64 = DATE refused",
    )
    assert_equal(
        _pushed_rows(bytes, _cmp(BIN_EQ, "n", ScalarValue.timestamp_micros(1))),
        _REFUSED, "INT64 = TIMESTAMP refused",
    )
    assert_equal(
        _pushed_rows(bytes, _cmp(BIN_EQ, "n", ScalarValue.from_int(2))),
        1, "INT64 = 2 stays pushed",
    )
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.date32(19000))
    vals.append(ScalarValue.timestamp_micros(1))
    var in_pred = Expr.in_list_node(Expr.col_ref("day"), vals^)
    assert_equal(_pushed_rows(bytes, in_pred), _REFUSED, "day IN mixed refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
