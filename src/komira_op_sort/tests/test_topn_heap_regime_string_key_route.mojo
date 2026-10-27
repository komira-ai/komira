# =============================================================================
# `ORDER BY <string> ... LIMIT n` in the regime that selects the bounded heap
# =============================================================================
#
# `_execute_topn_sink` takes the bounded heap (`sort_topn_heap`, O(N log K))
# when `num_rows > k * TOPN_HEAP_RATIO` and every key is heap-comparable
# (`_heap_can_order_all_keys`). A STRING top-N fixture smaller than `8 * K`
# never reaches the heap, so it proves nothing about it: every fixture here is
# 96 rows with K <= 10, and `test_every_case_here_is_in_the_heap_regime`
# asserts that arithmetic from the same `TOPN_HEAP_RATIO` the router reads, so
# shrinking the fixture or raising the ratio turns this file red instead of
# quietly testing the other arm.
#
# The oracles are hardcoded from the DuckDB CLI over the identical 96 rows:
#     CREATE TABLE t(s VARCHAR, v BIGINT, g BIGINT);
#     INSERT INTO t VALUES (...);                -- the fixture below, in order
#     SELECT s, v FROM t ORDER BY s ASC LIMIT 3;                  -- case 1
#     SELECT s, v FROM t ORDER BY s DESC LIMIT 3;                 -- case 2
#     SELECT s, v FROM t ORDER BY s ASC LIMIT 5;                  -- case 3
#     SELECT s, v FROM t ORDER BY s ASC, v ASC LIMIT 10;          -- case 4
#     SELECT g, s, v FROM t ORDER BY g ASC, s ASC LIMIT 5;        -- case 5
#     SELECT s, v FROM t ORDER BY s DESC, v ASC LIMIT 10;         -- case 6
#     SELECT v FROM t ORDER BY v DESC LIMIT 5;                    -- case 7
#
# Compare semantics the oracles pin (DuckDB default VARCHAR = bytewise):
# EMPTY sorts first; a leading SPACE (0x20) < digits (0x30) < uppercase
# ('A'=0x41) < lowercase ('a'=0x61); a prefix is LESS than its extension
# ("apple" < "apple pie"); a non-ASCII lead byte outranks all of ASCII
# ("Ünicode" starts 0xC3, so it sorts LAST ascending).
#
# The tie section (case 3) is deliberately weaker than its neighbours: its K-cut
# lands inside a 3-row `Apple` tie, and DuckDB does not fix intra-tie row
# order under LIMIT, so it pins the key sequence and the SET of payloads. case 4
# and case 6 add the unique `v` as a secondary key, which makes the order total,
# and pin full rows.
#
# A byte comparison that treated bytes as signed would order "Ünicode" first
# instead of last; the "Ünicode" cases fail on that.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.batch_view import BatchView
from komira_physical_plan.physical_plan import TopNSinkData

from komira_op_sort.sort_topn_sink import (
    TOPN_HEAP_RATIO,
    _execute_topn_sink,
    _heap_can_order_all_keys,
    _heap_can_order_key_type,
)


# =============================================================================
# The fixture — 96 rows, `[s STRING, v INT64, g INT64]`
# =============================================================================
#
# `v` is the row id, 1..96, UNIQUE — so `(s, v)` and `(g, s, v)` are TOTAL
# orders and can carry a full-row oracle even where `s` alone ties.
# `g` is `(row_index % 8)`, duplicated 12 ways — an
# INT64 the heap CAN order sitting in front of a STRING it cannot.
# =============================================================================

comptime _N_ROWS: Int = 96
comptime _N_SPECIAL: Int = 18


def _fixture_labels() -> List[String]:
    """The 96 `s` values, in insertion order == the oracle's `INSERT` order."""
    var s = List[String](capacity=_N_ROWS)
    s.append(String(""))            # v=1   empty sorts first
    s.append(String("  lead"))      # v=2   leading spaces (0x20)
    s.append(String("0numeric"))    # v=3   digit lead (0x30)
    s.append(String("Apple"))       # v=4  |
    s.append(String("Apple"))       # v=5  | the 3-row tie case 3 cuts through
    s.append(String("Apple"))       # v=6  |
    s.append(String("Banana"))      # v=7
    s.append(String("Zebra"))       # v=8   'Z'=0x5A still below 'a'=0x61
    s.append(String("aPPle"))       # v=9   'P'=0x50 < 'p'=0x70, so < "app"
    s.append(String("app"))         # v=10 |
    s.append(String("apple"))       # v=11 | prefix chain
    s.append(String("apple pie"))   # v=12 |
    s.append(String("banana"))      # v=13
    s.append(String("cherry"))      # v=14
    s.append(String("mango"))       # v=15
    s.append(String("zebra"))       # v=16
    s.append(String("zzz"))         # v=17
    s.append(String("Ünicode"))     # v=18  lead byte 0xC3 — sorts after ASCII
    # Filler: "row018".."row095", all DISTINCT, all between "mango" and
    # "zebra" ('m' < 'r' < 'z'). `i` is 2-digit over this whole range, so
    # "row0" + i reproduces the oracle's "row%03d" exactly.
    for i in range(_N_SPECIAL, _N_ROWS):
        s.append(String("row0") + String(i))
    return s^


def _fixture() raises -> RecordBatch:
    """`[s STRING, v INT64, g INT64]` — the batch every section below feeds."""
    var labels = _fixture_labels()
    var n = len(labels)

    var v = PrimitiveArray[DType.int64].allocate(n)
    var g = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
        g.set_typed[Scalar[DType.int64]](i, Int64(i % 8))

    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(Column.from_string(StringArray.from_strings(labels)))
    builder.add_column(Column.from_primitive[DType.int64](v^))
    builder.add_column(Column.from_primitive[DType.int64](g^))

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("g", ArrowType.INT64, False))
    return builder.build(sb.build())


def _spec(keys: List[String], desc: List[Bool], n: Int) raises -> TopNSinkData:
    var k = keys.copy()
    var d = desc.copy()
    return TopNSinkData(k^, d^, n)


def _topn(keys: List[String], desc: List[Bool], n: Int) raises -> RecordBatch:
    """Drive the router under test over a freshly built fixture."""
    return _execute_topn_sink(_fixture(), _spec(keys, desc, n))


def _s_at(rb: RecordBatch, row: Int) raises -> String:
    var bv = BatchView(rb)
    return bv.col_str(0).get(row).to_string()


def _i64_at(rb: RecordBatch, col: Int, row: Int) raises -> Int:
    return Int(rb.column_as_primitive_int64(col).load[1](row)[0])


def _keys1(a: String) -> List[String]:
    var k = List[String]()
    k.append(a)
    return k^


def _keys2(a: String, b: String) -> List[String]:
    var k = List[String]()
    k.append(a)
    k.append(b)
    return k^


def _desc1(a: Bool) -> List[Bool]:
    var d = List[Bool]()
    d.append(a)
    return d^


def _desc2(a: Bool, b: Bool) -> List[Bool]:
    var d = List[Bool]()
    d.append(a)
    d.append(b)
    return d^


def _assert_rows_sv(
    rb: RecordBatch,
    exp_s: List[String],
    exp_v: List[Int],
    label: String,
) raises:
    """Full row pin on `[s, v]` at every position."""
    assert_equal(rb.num_rows(), len(exp_s), label + ": row count")
    assert_equal(rb.num_columns(), 3, label + ": full frame [s, v, g] survives")
    for r in range(len(exp_s)):
        assert_equal(_s_at(rb, r), exp_s[r], label + ": s @" + String(r))
        assert_equal(_i64_at(rb, 1, r), exp_v[r], label + ": v @" + String(r))


# =============================================================================
# THE REGIME ASSERTION — the one that keeps every other test in this file
# honest. Read the banner at the top before touching any number here.
# =============================================================================


def test_every_case_here_is_in_the_heap_regime() raises:
    """Every (num_rows, k) below must satisfy the heap-selection predicate.

    `_execute_topn_sink` chooses the heap iff `num_rows > k *
    TOPN_HEAP_RATIO` and the key types allow it. If this
    arithmetic ever stops holding, every string section in this file silently
    starts measuring the full-sort arm instead — green, and
    proving nothing. Asserting it here, against the ratio the router itself
    reads, makes that failure mode LOUD.
    """
    assert_equal(len(_fixture_labels()), _N_ROWS, "fixture is 96 rows")
    assert_equal(_fixture().num_rows(), _N_ROWS, "batch is 96 rows")

    # The K values used by cases 1 to 7.
    var ks = List[Int]()
    ks.append(3)   # case 1, case 2
    ks.append(5)   # case 3, case 5, case 7
    ks.append(6)   # the mixed-direction composite (g DESC, s ASC)
    ks.append(10)  # case 4, case 6
    for i in range(len(ks)):
        assert_true(
            _N_ROWS > ks[i] * TOPN_HEAP_RATIO,
            String("K=") + String(ks[i]) + " is NOT in the heap regime: "
            + String(_N_ROWS) + " > " + String(ks[i]) + " * "
            + String(TOPN_HEAP_RATIO) + " is false",
        )

    # And the negative control that names the trap: the 10-row fixture the
    # pre-existing string TOP-N tests use is NOT in the regime at any of their
    # five K values, so they never exercise the heap.
    var legacy_ks = List[Int]()
    legacy_ks.append(3)
    legacy_ks.append(4)
    legacy_ks.append(5)
    for i in range(len(legacy_ks)):
        assert_true(
            not (10 > legacy_ks[i] * TOPN_HEAP_RATIO),
            String("the 10-row legacy fixture UNEXPECTEDLY reaches the heap at")
            + " K=" + String(legacy_ks[i])
            + " — if this now holds, the pre-existing string TOP-N tests DO"
            " cover the heap route and this file's premise needs rewriting",
        )

    # The fixture spans the byte-order edges the oracles pin.
    var labels = _fixture_labels()
    assert_equal(labels[0], String(""), "row 1 is the empty string")
    assert_equal(labels[17], String("Ünicode"), "row 18 is the non-ASCII one")
    assert_equal(labels[24], String("row024"), "filler naming rule holds @24")
    assert_equal(labels[95], String("row095"), "filler naming rule holds @95")


# =============================================================================
# case 1 — single STRING key, ASC, K=3.  DuckDB:
#     ('',1) ('  lead',2) ('0numeric',3)
# Rank 4 is 'Apple', so the cut is on a DISTINCT boundary -> full row pin.
# =============================================================================


def test_string_key_asc_k3_matches_duckdb() raises:
    var rb = _topn(_keys1(String("s")), _desc1(False), 3)
    var exp_s = List[String]()
    exp_s.append(String(""))
    exp_s.append(String("  lead"))
    exp_s.append(String("0numeric"))
    var exp_v = List[Int]()
    exp_v.append(1)
    exp_v.append(2)
    exp_v.append(3)
    _assert_rows_sv(rb, exp_s, exp_v, String("ORDER BY s ASC LIMIT 3"))


# =============================================================================
# case 2 — single STRING key, DESC, K=3.  DuckDB:
#     ('Ünicode',18) ('zzz',17) ('zebra',16)
# Rank 4 descending is 'row095' -> distinct boundary -> full row pin. Pins the
# non-ASCII lead byte (0xC3) outranking every ASCII byte.
# =============================================================================


def test_string_key_desc_k3_matches_duckdb() raises:
    var rb = _topn(_keys1(String("s")), _desc1(True), 3)
    var exp_s = List[String]()
    exp_s.append(String("Ünicode"))
    exp_s.append(String("zzz"))
    exp_s.append(String("zebra"))
    var exp_v = List[Int]()
    exp_v.append(18)
    exp_v.append(17)
    exp_v.append(16)
    _assert_rows_sv(rb, exp_s, exp_v, String("ORDER BY s DESC LIMIT 3"))


# =============================================================================
# case 3 — single STRING key, ASC, K=5 — THE CUT LANDS INSIDE THE 3-ROW `Apple`
# TIE (ranks 4, 5, 6). DuckDB:
#     ('',1) ('  lead',2) ('0numeric',3) ('Apple',?) ('Apple',?)
# KEY SEQUENCE is fully determined; the two payloads are a 2-subset of
# {4, 5, 6} and DuckDB licenses no more than that. Do not strengthen this:
# the order of tied rows under LIMIT is unspecified.
# =============================================================================


def test_string_key_asc_k5_tie_at_cut_matches_duckdb_key_sequence() raises:
    var rb = _topn(_keys1(String("s")), _desc1(False), 5)
    var label = String("ORDER BY s ASC LIMIT 5 (tie at cut)")

    assert_equal(rb.num_rows(), 5, label + ": row count")
    var exp_s = List[String]()
    exp_s.append(String(""))
    exp_s.append(String("  lead"))
    exp_s.append(String("0numeric"))
    exp_s.append(String("Apple"))
    exp_s.append(String("Apple"))
    for r in range(5):
        assert_equal(_s_at(rb, r), exp_s[r], label + ": s @" + String(r))

    # Ranks 1-3 are distinct keys, so their payloads ARE determined.
    assert_equal(_i64_at(rb, 1, 0), 1, label + ": v @0")
    assert_equal(_i64_at(rb, 1, 1), 2, label + ": v @1")
    assert_equal(_i64_at(rb, 1, 2), 3, label + ": v @2")

    # Ranks 4-5 come from the tie: membership only, and DISTINCT from each
    # other (a top-5 must not emit the same source row twice).
    var t0 = _i64_at(rb, 1, 3)
    var t1 = _i64_at(rb, 1, 4)
    assert_true(
        t0 >= 4 and t0 <= 6, label + ": v @3 is one of the three Apple rows"
    )
    assert_true(
        t1 >= 4 and t1 <= 6, label + ": v @4 is one of the three Apple rows"
    )
    assert_true(t0 != t1, label + ": the two tie rows are distinct source rows")


# =============================================================================
# case 4 — (STRING, INT64) keys, ASC/ASC, K=10 — a string key then an integer
# tie-break. `v` is unique, so the
# order is TOTAL and the full row is pinned at every position. DuckDB:
#     ('',1) ('  lead',2) ('0numeric',3) ('Apple',4) ('Apple',5) ('Apple',6)
#     ('Banana',7) ('Zebra',8) ('aPPle',9) ('app',10)
# =============================================================================


def test_string_then_int_keys_asc_k10_matches_duckdb() raises:
    var rb = _topn(
        _keys2(String("s"), String("v")), _desc2(False, False), 10
    )
    var exp_s = List[String]()
    exp_s.append(String(""))
    exp_s.append(String("  lead"))
    exp_s.append(String("0numeric"))
    exp_s.append(String("Apple"))
    exp_s.append(String("Apple"))
    exp_s.append(String("Apple"))
    exp_s.append(String("Banana"))
    exp_s.append(String("Zebra"))
    exp_s.append(String("aPPle"))
    exp_s.append(String("app"))
    var exp_v = List[Int]()
    exp_v.append(1)
    exp_v.append(2)
    exp_v.append(3)
    exp_v.append(4)
    exp_v.append(5)
    exp_v.append(6)
    exp_v.append(7)
    exp_v.append(8)
    exp_v.append(9)
    exp_v.append(10)
    _assert_rows_sv(rb, exp_s, exp_v, String("ORDER BY s ASC, v ASC LIMIT 10"))


# =============================================================================
# case 5 — (INT64, STRING) keys, ASC/ASC, K=5 — an integer key then a string:
# the heap orders the key in position 0 and not the one in position 1. This is the case
# a per-key (rather than all-keys) guard would get wrong. DuckDB:
#     (0,'',1) (0,'aPPle',9) (0,'row024',25) (0,'row032',33) (0,'row040',41)
# All five (g, s) pairs are distinct and rank 6 is (0,'row048'), so the full
# row is pinned.
# =============================================================================


def test_int_then_string_keys_asc_k5_matches_duckdb() raises:
    var rb = _topn(
        _keys2(String("g"), String("s")), _desc2(False, False), 5
    )
    var label = String("ORDER BY g ASC, s ASC LIMIT 5")

    assert_equal(rb.num_rows(), 5, label + ": row count")
    var exp_s = List[String]()
    exp_s.append(String(""))
    exp_s.append(String("aPPle"))
    exp_s.append(String("row024"))
    exp_s.append(String("row032"))
    exp_s.append(String("row040"))
    var exp_v = List[Int]()
    exp_v.append(1)
    exp_v.append(9)
    exp_v.append(25)
    exp_v.append(33)
    exp_v.append(41)
    for r in range(5):
        assert_equal(_s_at(rb, r), exp_s[r], label + ": s @" + String(r))
        assert_equal(_i64_at(rb, 1, r), exp_v[r], label + ": v @" + String(r))
        assert_equal(_i64_at(rb, 2, r), 0, label + ": g @" + String(r))


# =============================================================================
# case 6 — (STRING, INT64) keys, DESC/ASC, K=10 — mixed directions across a
# heap-capable and a heap-incapable key. DuckDB:
#     ('Ünicode',18) ('zzz',17) ('zebra',16) ('row095',96) ('row094',95)
#     ('row093',94) ('row092',93) ('row091',92) ('row090',91) ('row089',90)
# =============================================================================


def test_string_desc_int_asc_k10_matches_duckdb() raises:
    var rb = _topn(
        _keys2(String("s"), String("v")), _desc2(True, False), 10
    )
    var exp_s = List[String]()
    exp_s.append(String("Ünicode"))
    exp_s.append(String("zzz"))
    exp_s.append(String("zebra"))
    exp_s.append(String("row095"))
    exp_s.append(String("row094"))
    exp_s.append(String("row093"))
    exp_s.append(String("row092"))
    exp_s.append(String("row091"))
    exp_s.append(String("row090"))
    exp_s.append(String("row089"))
    var exp_v = List[Int]()
    exp_v.append(18)
    exp_v.append(17)
    exp_v.append(16)
    exp_v.append(96)
    exp_v.append(95)
    exp_v.append(94)
    exp_v.append(93)
    exp_v.append(92)
    exp_v.append(91)
    exp_v.append(90)
    _assert_rows_sv(rb, exp_s, exp_v, String("ORDER BY s DESC, v ASC LIMIT 10"))


# =============================================================================
# case 7 — NON-REGRESSION: an all-INT64 key list in the SAME regime still answers
# correctly. The guard must divert ONLY what the heap cannot compare; this is
# the case that still takes the heap, and it carries a STRING payload column
# through the heap's gather. DuckDB:
#     96 95 94 93 92
#
# This asserts VALUES, not the ROUTE — the two arms are value-identical when
# both are correct, so nothing in-process can distinguish them here. It is a
# guard against the guard over-firing, not a proof of which arm ran.
# =============================================================================


def test_int_key_desc_k5_still_answers_in_the_heap_regime() raises:
    var rb = _topn(_keys1(String("v")), _desc1(True), 5)
    var label = String("ORDER BY v DESC LIMIT 5 (all-INT64 keys)")
    assert_equal(rb.num_rows(), 5, label + ": row count")
    var exp_v = List[Int]()
    exp_v.append(96)
    exp_v.append(95)
    exp_v.append(94)
    exp_v.append(93)
    exp_v.append(92)
    for r in range(5):
        assert_equal(_i64_at(rb, 1, r), exp_v[r], label + ": v @" + String(r))
    # The STRING payload column rode through the heap's gather intact.
    assert_equal(_s_at(rb, 0), String("row095"), label + ": s payload @0")


# =============================================================================
# The router admits a STRING key to the heap
# =============================================================================
#
# S1..S7 hold whichever correct arm runs: a router that diverted a string key
# to the full-sort+slice arm would give the same values, only in O(N log N)
# time instead of O(N log K). No value assertion can tell the two arms apart,
# so the route is asserted directly. The router's decision is a `def` at
# module scope, which is read here: `_heap_can_order_key_type(STRING)` and
# `_heap_can_order_all_keys(fixture, ['g','s'])` must both be True. With the
# predicate True and the regime arithmetic True (asserted together below),
# the router's `if` selects the heap, so S1..S7 pin the heap's byte-wise
# STRING comparator (`sort_topn_heap._str_cmp3`).
# =============================================================================


def test_the_router_admits_string_keys_to_the_heap() raises:
    """Both conjuncts of the router's own `if`, read from the router.

    `_execute_topn_sink` selects the heap iff
    `num_rows > k * TOPN_HEAP_RATIO and _heap_can_order_all_keys(...)`. This
    asserts BOTH for the (INT64, STRING) and single-STRING key shapes, so it is a route proof rather
    than a reconstruction of one -- there is no third condition to be wrong
    about.
    """
    assert_true(
        _heap_can_order_key_type(ArrowType.STRING),
        "the router still refuses a STRING key the heap comparator can now"
        " order: `_heap_can_order_key_type(ArrowType.STRING)` is False",
    )

    var rb = _fixture()

    # A single STRING key.
    assert_true(
        _heap_can_order_all_keys(rb, _keys1(String("s"))),
        "ORDER BY s (a single STRING key) is still diverted off the heap",
    )
    # An INT64 in front of a STRING.
    assert_true(
        _heap_can_order_all_keys(rb, _keys2(String("g"), String("s"))),
        "ORDER BY g, s (INT64 leading a STRING) is still"
        " diverted off the heap",
    )
    # The same composite with the string trailing a different
    # INT64.
    assert_true(
        _heap_can_order_all_keys(rb, _keys2(String("v"), String("s"))),
        "ORDER BY v, s (INT64 then STRING) is still diverted off the heap",
    )

    # The OTHER conjunct, for the K values S1..S7 use -- so "the predicate is
    # True" cannot be mistaken for "the heap ran" while the regime is False.
    assert_true(
        _N_ROWS > 10 * TOPN_HEAP_RATIO,
        "K=10 is not in the heap regime, so S4/S6 do not reach the arm this"
        " test claims they now pin",
    )

    # And the negative side of the predicate, so a future widening that admits
    # a type with no comparator arm reds HERE rather than silently.
    assert_true(
        not _heap_can_order_key_type(ArrowType.BINARY),
        "BINARY was admitted to the heap. the heap comparator has no BINARY arm --"
        " a type admitted without one does not raise, it returns 'equal on all"
        " keys' for EVERY pair, which is a silently wrong top-K",
    )
    assert_true(
        not _heap_can_order_key_type(ArrowType.BOOL),
        "BOOL was admitted to the heap with no comparator arm",
    )


# =============================================================================
# THE MIXED-DIRECTION COMPOSITE WITH THE INT64 LEADING.
#
# Case 5 pins (INT64 ASC, STRING ASC). This pins the case
# where the two keys disagree about direction, which is what catches a
# comparator that applies one key's `descending` flag to the other, or that
# collapses a three-way compare into a Bool and loses the sign.
#
# DuckDB, over the same 96 rows:
#     SELECT g, s, v FROM t ORDER BY g DESC, s ASC LIMIT 6;
#       (7,'Zebra',8) (7,'row023',24) (7,'row031',32) (7,'row039',40)
#       (7,'row047',48) (7,'row055',56)
# `g = (row_index % 8)` so g=7 is rows v in {8,16,24,...,96}; their `s` values
# are 'Zebra'(v=8), 'zebra'(v=16) and then 'row023','row031',... ascending.
# 'Z'=0x5A < 'r'=0x72 < 'z'=0x7A, so 'Zebra' leads and 'zebra' is far down.
# Every (g, s) pair here is distinct -> full row pin.
# =============================================================================


def test_int_desc_then_string_asc_k6_matches_duckdb() raises:
    var rb = _topn(_keys2(String("g"), String("s")), _desc2(True, False), 6)
    var label = String("ORDER BY g DESC, s ASC LIMIT 6")

    assert_equal(rb.num_rows(), 6, label + ": row count")
    var exp_s = List[String]()
    exp_s.append(String("Zebra"))
    exp_s.append(String("row023"))
    exp_s.append(String("row031"))
    exp_s.append(String("row039"))
    exp_s.append(String("row047"))
    exp_s.append(String("row055"))
    var exp_v = List[Int]()
    exp_v.append(8)
    exp_v.append(24)
    exp_v.append(32)
    exp_v.append(40)
    exp_v.append(48)
    exp_v.append(56)
    for r in range(6):
        assert_equal(_s_at(rb, r), exp_s[r], label + ": s @" + String(r))
        assert_equal(_i64_at(rb, 1, r), exp_v[r], label + ": v @" + String(r))
        assert_equal(_i64_at(rb, 2, r), 7, label + ": g @" + String(r))


# =============================================================================
# A NULL-BEARING STRING KEY IS STILL DIVERTED, AND STILL CORRECT.
#
# THIS IS THE GUARD ON THE GUARD, AND IT IS NOT A TYPE CHECK. The heap
# comparator (`_HeapKeys.row_before`) reads the validity bitmap of nothing. An Arrow NULL string slot is an
# (offset, length=0) range -- `from_strings_with_validity`'s own docstring says
# so -- so on the heap a NULL would compare EQUAL to '' and land wherever the
# empty string lands. The arm this routes away from does not do that:
# `sort_indices_string` collates ASC -> NULLS FIRST, DESC -> NULLS LAST, and
# those two placements disagree with '' in the DESC direction.
#
# So the router refuses the heap a STRING key that carries nulls, and this
# pins BOTH halves: the refusal, and the answer that refusal preserves.
#
# The second test below is not a DuckDB parity assertion. Measured against
# the DuckDB CLI:
#
#     SELECT current_setting('default_null_order');   -->  NULLS_LAST
#     SELECT s IS NULL, s, v FROM n ORDER BY s ASC LIMIT 4;
#       false '' 2 | false '' 6 | false '' 10 | false '' 14
#
# i.e. DuckDB puts NULLs LAST ascending and this cell's top-4 is four EMPTY
# STRINGS, not four NULLs: the engine's derived default (ASC -> NULLS FIRST)
# is not DuckDB's (NULLS LAST). That divergence lives in the null-order
# policy, not in this kernel, and the guard above is what keeps it
# pre-existing instead of being silently replaced by a THIRD placement (the
# heap has no validity arm at all, so a NULL would tie with '' there).
#
# What is asserted is therefore the ENGINE's own stated contract for the arm
# the guard routes to -- `sort_indices_string`, ASC -> NULLS FIRST -- so that
# a change cannot move it in either direction without failing here.
# =============================================================================


comptime _NULL_FIXTURE_ROWS: Int = 40


def _null_bearing_fixture() raises -> RecordBatch:
    """`[s STRING NULLABLE, v INT64]`, 40 rows, 10 of them NULL in `s`."""
    var labels = List[String]()
    var valid = List[Bool]()
    var v = PrimitiveArray[DType.int64].allocate(_NULL_FIXTURE_ROWS)
    for i in range(_NULL_FIXTURE_ROWS):
        var m = i % 4
        if m == 0:
            labels.append(String(""))   # placeholder content for the NULL row
            valid.append(False)
        elif m == 1:
            labels.append(String(""))
            valid.append(True)
        elif m == 2:
            labels.append(String("a"))
            valid.append(True)
        else:
            labels.append(String("b"))
            valid.append(True)
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))

    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(labels, valid)
        )
    )
    builder.add_column(Column.from_primitive[DType.int64](v^))

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return builder.build(sb.build())


def test_a_null_bearing_string_key_is_refused_the_heap() raises:
    """The router must NOT hand a null-bearing STRING key to the heap."""
    var rb = _null_bearing_fixture()
    assert_equal(rb.num_rows(), _NULL_FIXTURE_ROWS, "null fixture row count")
    assert_true(
        rb.column_at(0).has_validity_buffer(),
        "the null fixture's `s` column carries no validity bitmap -- the case"
        " this test exists for is not being built",
    )
    # In the heap REGIME (40 > 4 * 8), so the type predicate is the only thing
    # that can divert it.
    assert_true(
        _NULL_FIXTURE_ROWS > 4 * TOPN_HEAP_RATIO,
        "the null fixture is not in the heap regime, so refusing the heap"
        " proves nothing here",
    )
    assert_true(
        not _heap_can_order_all_keys(rb, _keys1(String("s"))),
        "a NULL-bearing STRING key was admitted to the bounded heap, whose"
        " comparator reads no validity bitmap -- a NULL would compare equal to"
        " '' instead of collating NULLS FIRST/LAST",
    )
    # A null-free STRING key in the SAME batch shape is still admitted, so the
    # refusal is about nulls and not about strings having come back.
    var clean = _fixture()
    assert_true(
        _heap_can_order_all_keys(clean, _keys1(String("s"))),
        "the null guard over-fired: a null-FREE STRING key is diverted too",
    )


def test_a_null_bearing_string_key_still_answers_nulls_first_asc() raises:
    """The answer the refusal preserves -- the ENGINE's placement, not DuckDB's.

    `sort_indices_string` documents ASC -> NULLS FIRST and this pins that the
    diverted arm still delivers it. Read the section banner before changing
    this: DuckDB answers NULLS_LAST here and the divergence is
    deliberately left where it was found.
    """
    var rb = _execute_topn_sink(
        _null_bearing_fixture(), _spec(_keys1(String("s")), _desc1(False), 4)
    )
    var label = String("ORDER BY s ASC LIMIT 4 (null-bearing)")
    assert_equal(rb.num_rows(), 4, label + ": row count")
    # All four leading rows are NULL. `v` for a NULL row is one of
    # {1, 5, 9, ..., 37} (i % 4 == 0), and the four must be distinct.
    var seen = List[Int]()
    for r in range(4):
        assert_true(
            rb.column_at(0).is_null_at(r),
            label + ": s @" + String(r) + " is not NULL -- the diverted arm's"
            " documented ASC -> NULLS FIRST placement changed, which is what"
            " the null guard exists to prevent",
        )
        var vv = _i64_at(rb, 1, r)
        assert_true(
            vv % 4 == 1,
            label + ": v @" + String(r) + " = " + String(vv)
            + " is not one of the NULL rows",
        )
        for j in range(len(seen)):
            assert_true(
                seen[j] != vv, label + ": duplicate source row " + String(vv)
            )
        seen.append(vv)


# =============================================================================
# A null-bearing NUMERIC key: the heap and the full sort agree
# =============================================================================
#
# Numeric keys are ordered by stored value on every route, NULL slots
# included. A nullable INT64 key is therefore admitted to the heap, and the
# heap's rows are the first K rows of the full sort of the same batch, in
# both directions.
# =============================================================================


def _null_bearing_int_fixture() raises -> RecordBatch:
    """`[a INT64 NULLABLE, b INT64]`, 40 rows: `a` is NULL on every 4th row
    (the NULL slot holds 999) and `i % 3` elsewhere; `b` is the unique row
    number 1..40, which makes `(a, b)` a total order."""
    var a = PrimitiveArray[DType.int64].allocate_nullable(_NULL_FIXTURE_ROWS)
    var b = PrimitiveArray[DType.int64].allocate(_NULL_FIXTURE_ROWS)
    for i in range(_NULL_FIXTURE_ROWS):
        if i % 4 == 0:
            a.set_typed[Scalar[DType.int64]](i, Int64(999))
            a._set_null(i)
        else:
            a.set_typed[Scalar[DType.int64]](i, Int64(i % 3))
        b.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_primitive[DType.int64](a^))
    builder.add_column(Column.from_primitive[DType.int64](b^))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return builder.build(sb.build())


def _assert_heap_rows_are_the_full_sort_prefix(descending_a: Bool) raises:
    var keys = _keys2(String("a"), String("b"))
    var desc = _desc2(descending_a, False)
    assert_true(
        _heap_can_order_all_keys(_null_bearing_int_fixture(), keys),
        "a nullable INT64 key is not admitted to the heap",
    )
    var k = 4
    assert_true(_NULL_FIXTURE_ROWS > k * TOPN_HEAP_RATIO, "not in the heap regime")
    var heap = _execute_topn_sink(
        _null_bearing_int_fixture(), _spec(keys, desc, k)
    )
    var full = _execute_topn_sink(
        _null_bearing_int_fixture(), _spec(keys, desc, _NULL_FIXTURE_ROWS)
    )
    assert_equal(heap.num_rows(), k)
    assert_equal(full.num_rows(), _NULL_FIXTURE_ROWS)
    for r in range(k):
        assert_equal(_i64_at(heap, 1, r), _i64_at(full, 1, r), "b @" + String(r))
        assert_equal(_i64_at(heap, 0, r), _i64_at(full, 0, r), "a @" + String(r))


def test_a_null_bearing_int_key_heap_rows_match_full_sort_asc() raises:
    _assert_heap_rows_are_the_full_sort_prefix(False)


def test_a_null_bearing_int_key_heap_rows_match_full_sort_desc() raises:
    _assert_heap_rows_are_the_full_sort_prefix(True)


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_case_here_is_in_the_heap_regime]()
    suite.test[test_the_router_admits_string_keys_to_the_heap]()
    suite.test[test_int_desc_then_string_asc_k6_matches_duckdb]()
    suite.test[test_a_null_bearing_string_key_is_refused_the_heap]()
    suite.test[test_a_null_bearing_string_key_still_answers_nulls_first_asc]()
    suite.test[test_string_key_asc_k3_matches_duckdb]()
    suite.test[test_string_key_desc_k3_matches_duckdb]()
    suite.test[test_string_key_asc_k5_tie_at_cut_matches_duckdb_key_sequence]()
    suite.test[test_string_then_int_keys_asc_k10_matches_duckdb]()
    suite.test[test_int_then_string_keys_asc_k5_matches_duckdb]()
    suite.test[test_string_desc_int_asc_k10_matches_duckdb]()
    suite.test[test_int_key_desc_k5_still_answers_in_the_heap_regime]()
    suite.test[test_a_null_bearing_int_key_heap_rows_match_full_sort_asc]()
    suite.test[test_a_null_bearing_int_key_heap_rows_match_full_sort_desc]()
    suite^.run()
