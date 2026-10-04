# =============================================================================
# REGEXP THE PER-ROW PASS — the COLUMN kernel must equal the ONE-SHOT answer, row by row.
# =============================================================================
#
# ⛔ WHY THIS FILE EXISTS.  THE PER-ROW PASS deleted three per-row materializations from
# every `regexp_*` column kernel:
#
#   1. the SUBJECT COPY — `_row_bytes(col, i)` built an owned `String` and then
#      a `List[UInt8]` for every row; the kernels now pass `col.get_span(i)`,
#      a BORROWED view into the Arrow data buffer, straight to the Pike VM;
#   2. the VM's per-row STATE — `_run` constructed two `_ThreadList`s and a
#      slot vector on every call, i.e. once per row; they now live in ONE
#      caller-owned `RegexScratch` that is REUSED for the whole column;
#   3. the OUTPUT STAGING — `regexp_replace` staged the column as a
#      `List[String]` and re-serialized it through `StringArray.from_strings`;
#      it now assembles each value directly in an `ArrowStringBuilder`.
#
# ⛔⛔ EACH OF THE THREE FAILS SILENTLY WITH A CORRECT ROW COUNT.  That is the
# whole reason this file is a DIFFERENTIAL test and not a golden table:
#
#   * a scratch that is not re-armed between rows lets row i-1's live threads,
#     slot values or `seen` stamps decide row i — so row i gets a PLAUSIBLE
#     answer computed from the WRONG subject;
#   * an off-by-one in the span makes every row read its neighbour's bytes;
#   * a missing `end_value` / a mis-ordered partial push shifts the OFFSETS,
#     so value i is a splice of two rows.
#
# None of those changes the number of rows, and none of them is visible in a
# single-row unit test — every one of them needs a row whose correct answer
# DIFFERS from its neighbour's.  So the oracle here is:
#
#     kernel(column)[i]  ==  scalar(row i evaluated ALONE)  for every i
#
# The scalar spelling allocates a FRESH scratch per call and copies its own
# subject, so it cannot share a defect with the reused-scratch column path.
# The fixture is built to make that relation bite: rows alternate between
# match and no-match, lengths swing long->short (a short row after a long one
# is what an un-truncated buffer or a stale offset gets wrong), captures
# participate on some rows and not others, and a NULL and an empty string sit
# between two matching rows.
#
# ⭐ THE Q28 SELF-CONSISTENCY ORACLE is the last case: re-apply the query's own
# REGEXP to a value and assert it reproduces the key it was mapped to.  It is a
# relation BETWEEN TWO OUTPUT COLUMNS of the real ClickBench Q28 shape
# (`REGEXP_REPLACE(referer, '^https?://(?:www\.)?([^/]+)/.*$', '\1')` as the
# group key, `min(referer)` as a retained winner), and a row count cannot fake
# it: an unpacking error there returns a plausible WRONG string at a correct
# count.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.string_array import StringArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.eval.regexp_nfa import RegexProgram, RegexScratch
from komira_core.eval.regexp_functions import (
    eval_regexp_replace,
    eval_regexp_extract,
    eval_regexp_like,
    eval_regexp_count,
    eval_regexp_substr,
    regexp_replace_scalar,
    regexp_extract_scalar,
    regexp_like_scalar,
    regexp_count_scalar,
    split_g_flag,
    _str_bytes,
)


# ---------------------------------------------------------------------------
# The fixture.  Every property here is load-bearing — see the header.
# ---------------------------------------------------------------------------


def _rows() -> List[String]:
    """Adjacent rows must disagree: on WHETHER they match, on LENGTH, and on
    which capture groups participate."""
    var r = List[String]()
    r.append(String("http://www.example.com/a/b/c?q=1"))  # long, www. group
    r.append(String("x"))                                  # short, NO match
    r.append(String("https://foo.io/"))                    # no www., minimal tail
    r.append(String("http://www./a"))                      # the 1-in-1.34M backtrack
    r.append(String("not a url at all"))                   # NO match, mid length
    r.append(String("https://www.averyveryverylongdomainname.example.org/x/y/z/w"))
    r.append(String(""))                                   # empty
    r.append(String("http://b.co/"))                       # short match after empty
    r.append(String("ftp://www.nope.com/x"))               # NO match (scheme)
    r.append(String("http://www.example.com/a/b/c?q=1"))   # repeat of row 0
    r.append(String("https://tiny.z/q"))
    r.append(String("http://a/"))                          # 1-byte domain
    return r^


def _col(vals: List[String]) raises -> StringArray[HeapRegion]:
    return StringArray.from_strings(vals)


def _col_with_null(vals: List[String], null_at: Int) raises -> StringArray[HeapRegion]:
    var arr = StringArray.from_strings(vals)
    var vbm = Bitmap.create_all_valid(arr.length)
    vbm.clear(null_at)
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = 1
    return arr^


def _col_with_nulls(vals: List[String], null_idxs: List[Int]) raises -> StringArray[HeapRegion]:
    var arr = StringArray.from_strings(vals)
    var vbm = Bitmap.create_all_valid(arr.length)
    for k in range(len(null_idxs)):
        vbm.clear(null_idxs[k])
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = len(null_idxs)
    return arr^


comptime Q28_PAT = String("^https?://(?:www\\.)?([^/]+)/.*$")
comptime Q28_REP = String("\\1")


# ---------------------------------------------------------------------------
# 1. regexp_replace — the Q28 kernel.  Column vs one-shot, row by row.
# ---------------------------------------------------------------------------


def test_replace_column_equals_scalar_row_by_row() raises:
    """⛔ THE CORE RELATION.  A stale scratch, a mis-sliced span or a shifted
    offset each break exactly this and nothing else."""
    var vals = _rows()
    var col = _col(vals)
    var gs = split_g_flag(String(""))
    var prog = RegexProgram.compile(Q28_PAT, gs[0])
    var got = eval_regexp_replace(col, prog, Q28_REP, gs[1])
    assert_equal(got.length, len(vals))
    for i in range(len(vals)):
        var want = regexp_replace_scalar(vals[i], prog, Q28_REP, gs[1])
        assert_equal(got.get(i), want)
        # Byte length too: a splice can coincide on a prefix.
        assert_equal(len(got.get(i).as_bytes()), len(want.as_bytes()))


def test_replace_global_column_equals_scalar_row_by_row() raises:
    """The `g` (replace-all) arm drives the multi-segment assembly — several
    `push_bytes_partial`s per value — which is where a missing `end_value`
    or a mis-ordered partial push would show."""
    var vals = List[String]()
    vals.append(String("a1b22c333d"))
    vals.append(String("nodigits"))
    vals.append(String("9"))
    vals.append(String(""))
    vals.append(String("1a2b3c4d5e6f7g"))
    vals.append(String("z"))
    var col = _col(vals)
    var gs = split_g_flag(String("g"))
    var prog = RegexProgram.compile(String("[0-9]+"), gs[0])
    var got = eval_regexp_replace(col, prog, String("<\\0>"), gs[1])
    for i in range(len(vals)):
        assert_equal(got.get(i), regexp_replace_scalar(vals[i], prog, String("<\\0>"), gs[1]))


def test_replace_zero_width_and_backslash_template() raises:
    """The two template escapes (`\\\\` -> one backslash, `\\N` -> a group) and
    the RE2 GlobalReplace empty-match rule, which is the trickiest control flow
    in the streamed assembler."""
    var vals = List[String]()
    vals.append(String("abc"))
    vals.append(String(""))
    vals.append(String("aXbXc"))
    vals.append(String("q"))
    var col = _col(vals)
    var gs = split_g_flag(String("g"))
    var prog = RegexProgram.compile(String("X*"), gs[0])
    var got = eval_regexp_replace(col, prog, String("\\\\-"), gs[1])
    for i in range(len(vals)):
        assert_equal(got.get(i), regexp_replace_scalar(vals[i], prog, String("\\\\-"), gs[1]))


def test_replace_non_ascii_rows_are_byte_faithful() raises:
    """A multi-byte subject through the SPAN path: the byte-count assertion is
    what separates 'different string' from 'doubled bytes'."""
    var vals = List[String]()
    vals.append(String("Straße"))
    vals.append(String("plain"))
    vals.append(String("日本語のテキスト"))
    vals.append(String("a"))
    var col = _col(vals)
    var gs = split_g_flag(String(""))
    var prog = RegexProgram.compile(String("^(.*)$"), gs[0])
    var got = eval_regexp_replace(col, prog, String("\\1"), gs[1])
    for i in range(len(vals)):
        assert_equal(got.get(i), vals[i])
        assert_equal(len(got.get(i).as_bytes()), len(vals[i].as_bytes()))


def test_replace_null_row_between_matching_rows() raises:
    """A NULL must not consume a value slot — if it does, every row after it
    shifts by one and the count still checks out."""
    var vals = _rows()
    var col = _col_with_null(vals, 3)
    var gs = split_g_flag(String(""))
    var prog = RegexProgram.compile(Q28_PAT, gs[0])
    var got = eval_regexp_replace(col, prog, Q28_REP, gs[1])
    assert_equal(got.length, len(vals))
    assert_equal(got.null_count, 1)
    assert_true(got.is_null(3))
    for i in range(len(vals)):
        if i == 3:
            continue
        assert_false(got.is_null(i))
        assert_equal(got.get(i), regexp_replace_scalar(vals[i], prog, Q28_REP, gs[1]))


# ---------------------------------------------------------------------------
# 2. The other kernels that THE PER-ROW PASS re-pointed at the span + the shared scratch.
# ---------------------------------------------------------------------------


def test_extract_column_equals_scalar_row_by_row() raises:
    var vals = _rows()
    var col = _col(vals)
    var prog = RegexProgram.compile(Q28_PAT, String(""))
    var got = eval_regexp_extract(col, prog, 1)
    for i in range(len(vals)):
        assert_equal(got.get(i), regexp_extract_scalar(vals[i], prog, 1))


def test_like_column_equals_scalar_row_by_row() raises:
    """`use_like_fastpath=False` forces every row through the Pike VM — the
    arm THE PER-ROW PASS changed.  The fast path would route around it and prove nothing.
    """
    var vals = _rows()
    var col = _col(vals)
    var prog = RegexProgram.compile(Q28_PAT, String(""))
    var got = eval_regexp_like(col, prog, use_like_fastpath=False)
    for i in range(len(vals)):
        assert_equal(got.get(i), regexp_like_scalar(vals[i], prog))


def test_count_column_equals_scalar_row_by_row() raises:
    """`regexp_count` runs find_all_in, i.e. MANY `_run`s per row off ONE
    scratch — the densest re-arm in the tree."""
    var vals = List[String]()
    vals.append(String("a-b-c-d-e"))
    vals.append(String("none"))
    vals.append(String("-"))
    vals.append(String(""))
    vals.append(String("-x-x-x-x-x-x-"))
    vals.append(String("z"))
    var col = _col(vals)
    var prog = RegexProgram.compile(String("-"), String(""))
    var got = eval_regexp_count(col, prog)
    for i in range(len(vals)):
        assert_equal(Int(got.get(i)), regexp_count_scalar(vals[i], prog))


def test_substr_column_null_on_no_match_is_preserved() raises:
    var vals = _rows()
    var col = _col(vals)
    var prog = RegexProgram.compile(String("[a-z]+\\.(com|io|org)"), String(""))
    var got = eval_regexp_substr(col, prog)
    for i in range(len(vals)):
        var m = prog.find(_str_bytes(vals[i]))
        if m.matched:
            assert_false(got.is_null(i))
        else:
            assert_true(got.is_null(i))


# ---------------------------------------------------------------------------
# 3. The scratch itself: reuse across rows, across SUBJECT LENGTHS, and across
#    PROGRAMS of different instruction counts.
# ---------------------------------------------------------------------------


def test_one_scratch_across_many_subjects_matches_fresh_scratch() raises:
    """Drive `*_with` directly.  A long subject followed by a short one is the
    ordering that catches a thread list that was not truncated."""
    var prog = RegexProgram.compile(Q28_PAT, String(""))
    var vals = _rows()
    var sc = RegexScratch()
    for i in range(len(vals)):
        var b = _str_bytes(vals[i])
        var reused = prog.find_with(Span(b), sc)
        var fresh = prog.find(b)            # one-shot: its own scratch
        assert_equal(reused.matched, fresh.matched)
        assert_equal(reused.start, fresh.start)
        assert_equal(reused.end, fresh.end)
        assert_equal(len(reused.slots), len(fresh.slots))
        for k in range(len(fresh.slots)):
            assert_equal(reused.slots[k], fresh.slots[k])


def test_one_scratch_across_different_programs() raises:
    """The scratch is sized off the program's instruction count; a program of a
    DIFFERENT length must resize it rather than index a stale `seen_gen`."""
    var short_p = RegexProgram.compile(String("a"), String(""))
    var long_p = RegexProgram.compile(Q28_PAT, String(""))
    var subj = _str_bytes(String("http://www.example.com/a"))
    var sc = RegexScratch()
    for _ in range(3):
        var a1 = _prog_span_match(short_p, subj, sc)
        assert_equal(a1, short_p.is_match(subj))
        var a2 = _prog_span_match(long_p, subj, sc)
        assert_equal(a2, long_p.is_match(subj))


def _prog_span_match(p: RegexProgram, b: List[UInt8], mut sc: RegexScratch) -> Bool:
    return p.is_match_with(Span(b), sc)


# ---------------------------------------------------------------------------
# 4. ⭐ THE Q28 SELF-CONSISTENCY ORACLE (the relation the dispatch named).
# ---------------------------------------------------------------------------


def test_q28_key_is_reproducible_from_the_retained_referer() raises:
    """Re-apply Q28's own REGEXP to each retained `min(referer)` and assert it
    reproduces the key that row was grouped under.

    ⛔ A ROW COUNT CANNOT FAKE THIS.  The retained winner is carried as a packed
    (batch, row) pair; an unpacking error hands back a PLAUSIBLE WRONG STRING at
    a perfectly correct count, and the only thing that catches it is a relation
    between two output columns.  Here the two columns are produced by the two
    spellings THE PER-ROW PASS must keep identical — the column kernel and the one-shot —
    so the assertion also pins the span/scratch/offset triple end to end.
    """
    var vals = _rows()
    var col = _col(vals)
    var gs = split_g_flag(String(""))
    var prog = RegexProgram.compile(Q28_PAT, gs[0])
    var keys = eval_regexp_replace(col, prog, Q28_REP, gs[1])
    var n_matched = 0
    for i in range(len(vals)):
        var key = keys.get(i)
        var retained = vals[i]
        if regexp_like_scalar(retained, prog):
            # The row DID match: its key is the captured domain, and re-running
            # the pattern on the retained value must reproduce it exactly.
            n_matched += 1
            assert_equal(regexp_extract_scalar(retained, prog, 1), key)
            assert_true(len(key.as_bytes()) > 0)
            # and the key must not contain a '/', by construction of [^/]+
            for b in key.as_bytes():
                assert_true(b != UInt8(ord("/")))
        else:
            # No match -> REGEXP_REPLACE returns the subject unchanged.
            assert_equal(key, retained)
    # Non-vacuity: the relation above is only evidence if rows actually matched
    # AND rows actually did not.
    assert_true(n_matched >= 5)
    assert_true(n_matched < len(vals))


# ---------------------------------------------------------------------------
# 5. The shapes the BENCHMARK never presents — added by the adversarial
#    review of THE PER-ROW PASS.  Each is a branch of the STREAMED
#    builder that no arm above reaches.
# ---------------------------------------------------------------------------


def test_replace_empty_column_is_an_empty_column() raises:
    """n == 0 is a REACHABLE batch (a filter that kept nothing) and it is the
    one shape the streamed builder finalizes with ZERO `end_value` calls —
    `offsets == [0]`, `data` empty — which the `List[String]` +
    `from_strings` path it replaced never had to express."""
    var prog = RegexProgram.compile(Q28_PAT, String(""))
    var col = _col(List[String]())
    var got = eval_regexp_replace(col, prog, Q28_REP, False)
    assert_equal(got.length, 0)
    assert_equal(got.null_count, 0)


def test_replace_all_null_column_keeps_every_row_null() raises:
    """EVERY row null.  `push_null` arms the builder's LAZY validity on row 0
    with a ZERO-LENGTH back-fill — the branch a mid-column null (the arm
    above) never takes, because by then there are prior rows to back-fill."""
    var vals = _rows()
    var idxs = List[Int]()
    for i in range(len(vals)):
        idxs.append(i)
    var col = _col_with_nulls(vals, idxs)
    var prog = RegexProgram.compile(Q28_PAT, String(""))
    var got = eval_regexp_replace(col, prog, Q28_REP, False)
    assert_equal(got.length, len(vals))
    assert_equal(got.null_count, len(vals))
    for i in range(len(vals)):
        assert_true(got.is_null(i))


def test_replace_leading_and_trailing_null_rows() raises:
    """A null at row 0 AND at row n-1, with live rows between them.

    The trailing null is the only row whose offset has no successor to
    disagree with, so a mis-ordered `_append_offset`/`_mark_present` pair in
    `end_value`/`push_null` shows HERE and in no other arm."""
    var vals = _rows()
    var idxs = List[Int]()
    idxs.append(0)
    idxs.append(len(vals) - 1)
    var col = _col_with_nulls(vals, idxs)
    var gs = split_g_flag(String(""))
    var prog = RegexProgram.compile(Q28_PAT, gs[0])
    var got = eval_regexp_replace(col, prog, Q28_REP, gs[1])
    assert_equal(got.length, len(vals))
    assert_equal(got.null_count, 2)
    assert_true(got.is_null(0))
    assert_true(got.is_null(len(vals) - 1))
    for i in range(1, len(vals) - 1):
        assert_false(got.is_null(i))
        assert_equal(got.get(i), regexp_replace_scalar(vals[i], prog, Q28_REP, gs[1]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
