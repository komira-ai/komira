# =============================================================================
# A DICTIONARY group key is numbered in
# FIRST-SEEN order, exactly like the dense STRING form of the same rows
# =============================================================================
#
# The grouped COUNT(DISTINCT) resident-collect route now hands the parallel
# driver a dictionary-encoded parquet string key as ONE `DICTIONARY` column
# (codes + a unified dictionary) instead of a dense `STRING` column. The
# driver's DICTIONARY arm (`agg_cd_dictkey_encode.encode_dict_key_first_seen`)
# must then emit the SAME batch the STRING arm emits for the same rows — the
# group ids ARE the emit order and the Top-K tie order, so the same SET of
# (key, count) pairs is not enough.
#
# WHAT THIS FILE PROVES:
#   §1  a DICTIONARY arm that numbers groups by dictionary CODE (the arm this
#       replaced): the fixture's dictionary is in REVERSE first-seen order, so
#       code order and first-seen order disagree on every group;
#   §2  a DICTIONARY arm that trusts the dictionary to be distinct: one value
#       is stored under TWO codes and rows use both, so a code-keyed arm emits
#       it as two groups with split counts;
#   §3  a numbering that depends on the task count (T = 1, 2, 3, 7);
#   §4  a window read from the buffer start instead of the column's `_offset`
#       (a zero-copy `Column.slice`);
#   §5  an out-of-range code read out of bounds instead of refused by name.
#
# The ROUTE (the driver's DICTIONARY key goes through this encode, seen by its
# witness counter) is tested with the driver.

from std.collections import Dict, List, Optional, Set
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_dictkey_encode import (
    cd_dictkey_encode_count,
    encode_dict_key_first_seen,
    reset_cd_dictkey_encode_count,
)


comptime _WORKERS: Int = 4
comptime _N: Int = 70_000


# =============================================================================
# Fixtures
# =============================================================================


def _skew_value(r: Int) -> String:
    """A skewed shape: nine rows in ten are ONE value; the rest scatter over
    ~211 values whose first appearances land in every task, an EMPTY value,
    multi-byte UTF-8, a shared prefix, and values that first appear only in
    the last seventh of the rows."""
    if r % 10 != 0:
        return String("iPad")
    if r >= 60_000 and r % 140 == 0:
        return String("late-") + String(r)
    var v = ((r // 10) * 2_654_435_761) % 211
    if v == 0:
        return String("")
    if v % 17 == 0:
        return String("ÄÖÜ-многобайт-") + String(v)
    if v % 5 == 0:
        return String("shared-prefix-model-") + String(v)
    return String("m") + String(v)


def _rows(n: Int) -> List[String]:
    var out = List[String](capacity=n)
    for r in range(n):
        out.append(_skew_value(r))
    return out^


struct _DictFixture(Movable):
    """A dictionary in REVERSE first-seen order, with one UNREFERENCED entry
    and `iPad` stored TWICE (every 7th `iPad` row uses the second code)."""

    var dict_vals: List[String]
    var codes: List[Int32]

    def __init__(out self, imm vals: List[String]):
        var first = List[String]()
        var seen = Set[String]()
        for i in range(len(vals)):
            if vals[i] not in seen:
                seen.add(vals[i])
                first.append(vals[i])
        # Reverse first-seen order, an unreferenced entry in the middle, and a
        # duplicate of the heavy value at the end.
        var dv = List[String]()
        var i = len(first) - 1
        while i >= 0:
            dv.append(first[i])
            if i == len(first) // 2:
                dv.append(String("never-referenced"))
            i -= 1
        dv.append(String("iPad"))
        var dup_code = len(dv) - 1
        var code_of = Dict[String, Int]()
        for d in range(len(dv) - 1):
            if dv[d] not in code_of:
                code_of[dv[d]] = d
        var codes = List[Int32](capacity=len(vals))
        var heavy_seen = 0
        for r in range(len(vals)):
            var c = code_of.get(vals[r], -1)
            if vals[r] == "iPad":
                heavy_seen += 1
                if heavy_seen % 7 == 0:
                    c = dup_code
            codes.append(Int32(c))
        self.dict_vals = dv^
        self.codes = codes^

    def column(self) raises -> Column[HeapRegion]:
        var idx = PrimitiveArray[DType.int32].from_list(self.codes)
        var sda = StringDictionaryArray.from_parts(
            idx^, StringArray.from_strings(self.dict_vals)
        )
        return Column.from_dictionary(sda)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _first_seen_ids(imm vals: List[String]) -> Tuple[List[Int], List[String]]:
    """The INDEPENDENT oracle: id g is the g-th distinct value in row order."""
    var ids = List[Int](capacity=len(vals))
    var order = List[String]()
    var id_of = Dict[String, Int]()
    for r in range(len(vals)):
        var g = id_of.get(vals[r], -1)
        if g < 0:
            g = len(order)
            id_of[vals[r]] = g
            order.append(vals[r])
        ids.append(g)
    return (ids^, order^)


# =============================================================================
# The direct encode
# =============================================================================


def _encode(
    imm c: Column[HeapRegion], n: Int, n_tasks: Int
) raises -> Tuple[List[Int], List[String]]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var encoded = List[Int]()
    var rev_bytes = List[UInt8]()
    var rev_starts = List[Int]()
    var rev_lens = List[Int]()
    encode_dict_key_first_seen(
        disp, c, n, encoded, rev_bytes, rev_starts, rev_lens, n_tasks
    )
    var vals = List[String]()
    for g in range(len(rev_starts)):
        var s = rev_starts[g]
        vals.append(
            String(
                StringSlice(
                    unsafe_from_utf8=Span(rev_bytes)[s : s + rev_lens[g]]
                )
            )
        )
    return (encoded^, vals^)


def _assert_first_seen(
    imm got: Tuple[List[Int], List[String]],
    imm want: Tuple[List[Int], List[String]],
    tag: String,
) raises:
    ref ge = got[0]
    ref gv = got[1]
    ref we = want[0]
    ref wv = want[1]
    assert_equal(len(gv), len(wv), tag + ": distinct-value count")
    for g in range(len(wv)):
        assert_equal(gv[g], wv[g], tag + ": value of id " + String(g))
    assert_equal(len(ge), len(we), tag + ": row count")
    for r in range(len(we)):
        if ge[r] != we[r]:
            assert_equal(ge[r], we[r], tag + ": id of row " + String(r))


def test_numbering_is_first_seen_at_every_task_count() raises:
    """§1 + §2 + §3: reverse-ordered, non-distinct dictionary; the ids must be
    the first-seen ranks of the VALUES at T = 1, 2, 3 and 7."""
    var vals = _rows(_N)
    var fx = _DictFixture(vals)
    var c = fx.column()
    var want = _first_seen_ids(vals)
    for t in [1, 2, 3, 7]:
        var got = _encode(c, _N, t)
        _assert_first_seen(got, want, String("T=") + String(t))


def test_window_is_read_from_the_column_offset() raises:
    """§4: a zero-copy slice carries `_offset > 0`; the encode must read rows
    [start, start + len), not [0, len)."""
    var vals = _rows(_N)
    var fx = _DictFixture(vals)
    var c = fx.column()
    var start = 12_345
    var length = 40_000
    var win = c.slice(start, length)
    assert_true(win._offset == start, "fixture: the slice must carry _offset")
    var sub = List[String](capacity=length)
    for r in range(start, start + length):
        sub.append(vals[r])
    var want = _first_seen_ids(sub)
    var got = _encode(win, length, 3)
    _assert_first_seen(got, want, "window")


def test_out_of_range_code_is_refused_by_name() raises:
    """§5: a code past the dictionary raises a NAMED error."""
    var codes = List[Int32]()
    for r in range(1_000):
        codes.append(Int32(r % 3))
    codes[777] = Int32(9)
    var dv = List[String]()
    dv.append(String("a"))
    dv.append(String("b"))
    dv.append(String("c"))
    var sda = StringDictionaryArray.from_parts(
        PrimitiveArray[DType.int32].from_list(codes),
        StringArray.from_strings(dv),
    )
    var c = Column.from_dictionary(sda)
    var raised = False
    try:
        _ = _encode(c, 1_000, 2)
    except e:
        raised = True
        assert_true(
            String(e).find("outside the column's dictionary") >= 0,
            "the refusal must name the defect, got: " + String(e),
        )
    assert_true(raised, "an out-of-range code must raise")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
