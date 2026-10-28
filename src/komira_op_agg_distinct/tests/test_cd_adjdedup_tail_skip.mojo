# =============================================================================
# CD-ADJDEDUP — the grouped COUNT(DISTINCT)
# accumulator drops a value equal to its (worker, group) cell's TAIL instead of
# appending it.
#
# WHAT IS PINNED, AND WHY THESE ASSERTIONS AND NOT A WALL:
#
#   1. VALUE IDENTITY. Per group, the distinct SET of what the cell holds is the
#      same with the lever ON and OFF (and equal to a linear-scan oracle over the
#      raw arrays). The finalize counts the distinct union of a group's runs, so
#      an equal set per group IS an equal answer downstream. A comparison against
#      the tail of a DIFFERENT cell, or a skip decided on a NULL row's data
#      word, changes a set here.
#   2. THE LEVER RAN. `stat_adj_skipped` equals an INDEPENDENT oracle count (rows
#      whose value equals the previous non-NULL value of the SAME group, across a
#      batch boundary), is > 0 on the fixture (vacuity guard), and the ON arm's
#      cells hold no two ADJACENT equal values.
#   3. CONSERVATION. `stat_appends + stat_adj_skipped` is the non-NULL value
#      count on both arms, so neither counter can be wrong alone.
#   4. THE OFF ARM (`adj_dedup_on = False`) appends every non-NULL value —
#      the append-everything route, byte for byte.
#
# The fixture interleaves groups on purpose: the skip is per CELL, so a run of
# equal values must survive other groups' rows landing between its members.
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)

from komira_op_agg_distinct.streaming_agg_count_distinct import (
    WorkerCDState,
)


struct _Fx(Copyable, Movable):
    """The raw arrays a batch is built from; every oracle reads THESE."""

    var keys: List[Int64]
    var vals: List[Int64]
    var val_nulls: List[Bool]

    def __init__(
        out self, var keys: List[Int64], var vals: List[Int64],
        var val_nulls: List[Bool],
    ):
        self.keys = keys^
        self.vals = vals^
        self.val_nulls = val_nulls^

    def n(self) -> Int:
        return len(self.keys)


def _interleaved(n: Int, lo: Int) -> _Fx:
    """Runs of 3 rows per key cycling over 5 keys; values in runs of 7 rows.
    A group therefore sees runs of equal values broken up by other groups'
    rows, and runs that end mid-group — both skip and no-skip cases."""
    var ks = List[Int64]()
    var vs = List[Int64]()
    var ns = List[Bool]()
    for j in range(n):
        var i = lo + j
        ks.append(Int64((i // 3) % 5))
        vs.append(Int64((i // 7) * 1_000_003 - 50))
        ns.append(False)
    return _Fx(ks^, vs^, ns^)


def _build_batch(imm f: _Fx) raises -> RecordBatch:
    """INT64 key `k` (non-null) + INT64 value `v`, nullable only when the
    fixture has a NULL value (so the absent-lane path is the common case)."""
    var n = f.n()
    var any_null = False
    for i in range(n):
        if f.val_nulls[i]:
            any_null = True
            break
    var rbb = RecordBatchBuilder.with_capacity(2)
    var karr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        karr.store[1](i, Scalar[DType.int64](f.keys[i]))
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    if any_null:
        var varr = PrimitiveArray[DType.int64].allocate_nullable(n)
        for i in range(n):
            varr.store[1](i, Scalar[DType.int64](f.vals[i]))
        for i in range(n):
            if f.val_nulls[i]:
                varr._set_null(i)
        rbb.add_column(Column.from_primitive[DType.int64](varr^))
    else:
        var varr = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            varr.store[1](i, Scalar[DType.int64](f.vals[i]))
        rbb.add_column(Column.from_primitive[DType.int64](varr^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, any_null))
    return rbb.build(sb.build())


def _run(imm fs: List[_Fx], adj: Bool) raises -> WorkerCDState:
    """Drive `consume_batch` once per fixture into ONE state, on the named
    arm (the field is what the env kill-switch sets at construction)."""
    var st = WorkerCDState(1)
    st.adj_dedup_on = adj
    var val_idx = List[Int]()
    val_idx.append(1)
    for i in range(len(fs)):
        var batch = _build_batch(fs[i])
        st.consume_batch(batch, 0, val_idx)
        _ = batch^
    return st^


def _contains(imm xs: List[Int64], v: Int64) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _oracle_distinct(imm fs: List[_Fx], key: Int64) -> List[Int64]:
    """Distinct non-NULL values of group `key`, linear scan, first-seen order."""
    var seen = List[Int64]()
    for b in range(len(fs)):
        for i in range(fs[b].n()):
            if fs[b].keys[i] != key or fs[b].val_nulls[i]:
                continue
            if not _contains(seen, fs[b].vals[i]):
                seen.append(fs[b].vals[i])
    return seen^


def _oracle_skips_and_values(imm fs: List[_Fx]) -> Tuple[Int, Int]:
    """(rows equal to the previous non-NULL value of their OWN group, non-NULL
    value count) — computed from the raw arrays, never from the state."""
    var last_key = List[Int64]()
    var last_val = List[Int64]()
    var skips = 0
    var nn = 0
    for b in range(len(fs)):
        for i in range(fs[b].n()):
            if fs[b].val_nulls[i]:
                continue
            nn += 1
            var k = fs[b].keys[i]
            var v = fs[b].vals[i]
            var at = -1
            for j in range(len(last_key)):
                if last_key[j] == k:
                    at = j
                    break
            if at < 0:
                last_key.append(k)
                last_val.append(v)
            elif last_val[at] == v:
                skips += 1
            else:
                last_val[at] = v
    return (skips, nn)


def _cell_set(imm st: WorkerCDState, key: Int64) -> List[Int64]:
    var out = List[Int64]()
    for g in range(len(st.group_keys)):
        if Int64(st.group_keys[g]) != key:
            continue
        for i in range(len(st.cd_bufs[0][g])):
            if not _contains(out, st.cd_bufs[0][g][i]):
                out.append(st.cd_bufs[0][g][i])
    return out^


def _assert_same_set(imm a: List[Int64], imm b: List[Int64], what: String) raises:
    assert_equal(len(a), len(b), what + ": distinct COUNT differs")
    for i in range(len(a)):
        assert_true(_contains(b, a[i]), what + ": a value is missing")


def _check(imm fs: List[_Fx], what: String) raises:
    var on = _run(fs, True)
    var off = _run(fs, False)
    var exp = _oracle_skips_and_values(fs)
    var want_skips = exp[0]
    var n_values = exp[1]
    assert_true(
        want_skips > 0,
        what + ": vacuity guard — the fixture has no adjacent duplicate, so"
        " nothing below could see the lever",
    )
    # 2. the lever ran, exactly as often as the oracle says.
    assert_equal(on.stat_adj_skipped, want_skips, what + ": ON skip count")
    # 3. conservation, both arms.
    assert_equal(
        on.stat_appends + on.stat_adj_skipped, n_values,
        what + ": ON counters do not partition the non-NULL values",
    )
    # 4. the kill-switch arm is append-every-value.
    assert_equal(off.stat_adj_skipped, 0, what + ": OFF arm skipped")
    assert_equal(off.stat_appends, n_values, what + ": OFF arm appends")
    # No two adjacent equal values survive in any ON cell.
    for g in range(len(on.group_keys)):
        ref cell = on.cd_bufs[0][g]
        for i in range(1, len(cell)):
            assert_true(
                cell[i] != cell[i - 1],
                what + ": gid " + String(g) + " kept an adjacent duplicate",
            )
    # 1. value identity, per group, against the arms and the oracle.
    assert_equal(len(on.group_keys), len(off.group_keys), what + ": groups")
    for g in range(len(off.group_keys)):
        var k = Int64(off.group_keys[g])
        var o = _oracle_distinct(fs, k)
        _assert_same_set(_cell_set(on, k), o, what + " ON key " + String(k))
        _assert_same_set(_cell_set(off, k), o, what + " OFF key " + String(k))


def test_tail_skip_is_value_identical_and_counted() raises:
    var fs = List[_Fx]()
    fs.append(_interleaved(4096, 0))
    _check(fs, "one batch")


def test_the_tail_survives_a_batch_boundary() raises:
    """The cell's tail is state, not a per-batch local: a run split across two
    morsels must still skip on the second morsel's first row."""
    var fs = List[_Fx]()
    fs.append(_interleaved(1001, 0))
    fs.append(_interleaved(1003, 1001))
    fs.append(_interleaved(997, 2004))
    _check(fs, "three batches")
    # And the boundary case explicitly: key 4, value 9 at the end of batch 1
    # and the start of batch 2.
    var a = List[_Fx]()
    var k1: List[Int64] = [Int64(4), 1, 4]
    var v1: List[Int64] = [Int64(8), 5, 9]
    var n1: List[Bool] = [False, False, False]
    a.append(_Fx(k1^, v1^, n1^))
    var k2: List[Int64] = [Int64(4), 4, 1]
    var v2: List[Int64] = [Int64(9), 10, 5]
    var n2: List[Bool] = [False, False, False]
    a.append(_Fx(k2^, v2^, n2^))
    var st = _run(a, True)
    assert_equal(st.stat_adj_skipped, 2, "boundary: key 4 v=9 and key 1 v=5")
    assert_equal(st.stat_appends, 4)


def test_null_values_are_never_a_tail() raises:
    """A NULL row is skipped BEFORE the tail compare and never becomes one:
    [5, NULL, 5] keeps one 5; a NULL whose data word is 0 followed by a real 0
    must APPEND that 0 (the NULL's word is meaningless)."""
    var ks: List[Int64] = [Int64(1), 1, 1, 2, 2, 1, 1]
    var vs: List[Int64] = [Int64(5), 5, 5, 0, 0, 6, 6]
    var ns: List[Bool] = [False, True, False, True, False, False, False]
    var fs = List[_Fx]()
    fs.append(_Fx(ks^, vs^, ns^))
    var st = _run(fs, True)
    assert_equal(st.stat_adj_skipped, 2, "the second 5 and the second 6")
    assert_equal(st.stat_appends, 3, "5, 6 in group 1; 0 in group 2")
    var g2 = _cell_set(st, Int64(2))
    assert_equal(len(g2), 1)
    assert_equal(g2[0], Int64(0))
    _check(fs, "nulls")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
