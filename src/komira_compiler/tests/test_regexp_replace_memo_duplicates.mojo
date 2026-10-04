# =============================================================================
# REGEXP-REPLACE MEMO — the memoised column must equal the ONE-SHOT answer,
# row by row, on a DUPLICATE-HEAVY column.
# =============================================================================
#
# ⛔ WHY THIS FILE EXISTS.  `eval_regexp_replace` now runs the pattern ONCE PER
# DISTINCT SUBJECT: an open-addressed table keyed on (hash, length, bytes)
# remembers each subject's produced bytes in a side arena and re-emits them for
# a repeat.  That buys 3.07x on real `referer` data — and it introduces three
# failure modes THAT A ROW COUNT CANNOT SEE, which is why the oracle here is a
# relation and not a golden table:
#
#   1. ⭐ A SECOND COPY OF THE CONTROL FLOW.  The memo cannot write through the
#      `ArrowStringBuilder` (it has to READ produced bytes back, and a push may
#      reallocate the buffer being read), so `_replace_into_arena` is a mirror
#      of `_replace_into` over a `List[UInt8]` sink.  Two mirrors DRIFT — an
#      empty-match rule, a zero-width advance or a `\N` rewrite branch that
#      diverges between them is a WRONG STRING at a CORRECT COUNT.
#   2. A HIT THAT EMITS THE WRONG SPAN.  The remembered value is an (lo, hi)
#      pair into the arena; an off-by-one, or recording the span before the VM
#      has written it, yields a plausible neighbouring value.
#   3. THE SAMPLE-AND-DISABLE BRANCH.  A column with no repeats turns the memo
#      OFF after 4,096 rows, so ONE column is served by TWO code paths and the
#      row where they meet is the one nothing else covers.
#
# The oracle is the same one `test_regexp_scratch_reuse_and_span_subject.mojo`
# uses, because it is the only one these defects cannot satisfy:
#
#     kernel(column)[i]  ==  scalar(row i evaluated ALONE)   for every i
#
# `regexp_replace_scalar` takes a fresh scratch and its own subject copy and
# goes through `_replace_one`, a THIRD spelling that shares no state with
# either of the other two — so a drift in the mirror cannot hide in it.
#
# ⭐ AND A SPOT-CHECK OF LITERAL EXPECTED STRINGS, because a relation between
# two spellings is satisfied by both being wrong the same way.
#
# The fixtures are built so the defects BITE:
#   * duplicates are NON-ADJACENT, so a hit is a genuine table answer and not
#     a "same as the previous row" accident;
#   * a repeated row's output is SHORTER and LONGER than its neighbours', so a
#     mis-sized span shows up as a splice;
#   * a repeated NON-MATCHING row (output == input) and a repeated row whose
#     capture is the WHOLE remaining string sit next to each other;
#   * NULLs and empty strings are interleaved BETWEEN two copies of the same
#     value, so an offset drift lands on a duplicate;
#   * one fixture crosses the 4,096-row sampling boundary with all-distinct
#     rows and then presents duplicates AFTER the memo has switched off.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.string_array import StringArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.eval.regexp_nfa import RegexProgram
from komira_core.eval.regexp_functions import (
    eval_regexp_replace,
    regexp_replace_scalar,
    split_g_flag,
)


comptime Q28_PAT = String("^https?://(?:www\\.)?([^/]+)/.*$")
comptime Q28_REP = String("\\1")


def _col(vals: List[String]) raises -> StringArray[HeapRegion]:
    return StringArray.from_strings(vals)


def _col_with_nulls(vals: List[String], null_idxs: List[Int]) raises -> StringArray[HeapRegion]:
    var arr = StringArray.from_strings(vals)
    var vbm = Bitmap.create_all_valid(arr.length)
    for k in range(len(null_idxs)):
        vbm.clear(null_idxs[k])
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = len(null_idxs)
    return arr^


def _palette() -> List[String]:
    """12 distinct subjects whose ANSWERS differ in length, in whether the
    pattern matched at all, and in whether the capture participated."""
    var p = List[String]()
    p.append(String("http://www.example.com/a/b/c?q=1"))          # -> example.com
    p.append(String("https://a.io/"))                             # -> a.io  (short)
    p.append(String("not a url at all"))                          # NO match -> itself
    p.append(String("https://www.averyverylongdomainname.org/x")) # -> long domain
    p.append(String("http://b/"))                                 # -> b  (1 byte)
    p.append(String("ftp://www.nope.com/x"))                      # NO match -> itself
    p.append(String("http://www./a"))                             # -> www. backtrack case
    p.append(String("https://tiny.z/q"))                          # -> tiny.z
    p.append(String("http://www.example.co/a"))                   # 1 byte off row 0's answer
    p.append(String("http://www.example.com/a/b/c?q=2"))          # same ANSWER as row 0,
    p.append(String("x"))                                         #   different SUBJECT
    p.append(String("http://zz.example.com/"))                    # -> zz.example.com
    return p^


def _dup_heavy(n: Int) -> List[String]:
    """`n` rows over the 12-value palette, ordered so a value's repeats are
    never adjacent (stride 7 against a 12-value palette is coprime, so the
    walk visits all 12 before repeating any)."""
    var p = _palette()
    var out = List[String]()
    for i in range(n):
        out.append(p[(i * 7) % len(p)])
    return out^


def _assert_column_equals_scalar(
    vals: List[String],
    null_idxs: List[Int],
    pattern: String,
    replacement: String,
    flags: String,
) raises:
    var col: StringArray[HeapRegion]
    if len(null_idxs) > 0:
        col = _col_with_nulls(vals, null_idxs)
    else:
        col = _col(vals)
    var gs = split_g_flag(flags)
    var prog = RegexProgram.compile(pattern, gs[0])
    var got = eval_regexp_replace(col, prog, replacement, gs[1])
    assert_equal(got.length, len(vals))
    var nulls_seen = 0
    for i in range(len(vals)):
        var is_null = False
        for k in range(len(null_idxs)):
            if null_idxs[k] == i:
                is_null = True
        if is_null:
            assert_true(got.is_null(i))
            nulls_seen += 1
            continue
        var want = regexp_replace_scalar(vals[i], prog, replacement, gs[1])
        assert_equal(got.get(i), want)
        # Byte length too: a splice can coincide on a prefix.
        assert_equal(len(got.get(i).as_bytes()), len(want.as_bytes()))
    assert_equal(nulls_seen, len(null_idxs))


# ---------------------------------------------------------------------------
# 1. The core relation on a duplicate-heavy column (the memo's hot path).
# ---------------------------------------------------------------------------


def test_replace_duplicate_heavy_equals_scalar() raises:
    """400 rows over 12 distinct subjects ⇒ 97% of rows are memo HITS.

    Every row here is answered by the table rather than the VM, so this is the
    case that a broken hit path, a mis-sized arena span, or a drift between
    `_replace_into_arena` and `_replace_into` gets wrong."""
    _assert_column_equals_scalar(_dup_heavy(400), List[Int](), Q28_PAT, Q28_REP, String(""))


def test_replace_duplicate_heavy_with_nulls_equals_scalar() raises:
    """The same column with NULLs sitting BETWEEN two copies of one value.

    A NULL must not consume a memo slot and must not shift the offset of the
    duplicate that follows it."""
    var vals = _dup_heavy(400)
    var nulls = List[Int]()
    nulls.append(0)
    nulls.append(13)
    nulls.append(14)
    nulls.append(199)
    nulls.append(399)
    _assert_column_equals_scalar(vals, nulls, Q28_PAT, Q28_REP, String(""))


def test_replace_duplicate_heavy_with_empty_strings_equals_scalar() raises:
    """An EMPTY subject is a legal repeated key whose answer is also empty —
    bit-identical to a never-written arena span, so it is the one value a
    "span (0,0) means miss" bug answers correctly by accident and every other
    value it does not."""
    var vals = List[String]()
    var p = _palette()
    for i in range(300):
        if i % 5 == 0:
            vals.append(String(""))
        else:
            vals.append(p[(i * 7) % len(p)])
    _assert_column_equals_scalar(vals, List[Int](), Q28_PAT, Q28_REP, String(""))


# ---------------------------------------------------------------------------
# 2. Literal expected values — the relation above is satisfied by two
#    spellings that are wrong in the SAME way; this is not.
# ---------------------------------------------------------------------------


def test_replace_duplicate_heavy_literal_spot_check() raises:
    """Pinned answers for the first 12 rows of the duplicate-heavy column,
    written out by hand from the Q28 pattern's semantics."""
    var vals = _dup_heavy(24)
    var col = _col(vals)
    var gs = split_g_flag(String(""))
    var prog = RegexProgram.compile(Q28_PAT, gs[0])
    var got = eval_regexp_replace(col, prog, Q28_REP, gs[1])
    # Transcribe the ANSWER for each of the 12 palette entries once, then
    # assert it at whichever row the stride puts that entry on.
    var p = _palette()
    var expect = List[String]()
    expect.append(String("example.com"))                # http://www.example.com/a/b/c?q=1
    expect.append(String("a.io"))                       # https://a.io/
    expect.append(String("not a url at all"))           # no match -> unchanged
    expect.append(String("averyverylongdomainname.org"))  # the `www.` IS consumed by (?:www\.)?
    expect.append(String("b"))                          # http://b/
    expect.append(String("ftp://www.nope.com/x"))       # no match -> unchanged
    expect.append(String("www."))                       # http://www./a
    expect.append(String("tiny.z"))                     # https://tiny.z/q
    expect.append(String("example.co"))                 # http://www.example.co/a
    expect.append(String("example.com"))                # ?q=2 — same answer, other subject
    expect.append(String("x"))                          # no match -> unchanged
    expect.append(String("zz.example.com"))             # http://zz.example.com/
    for i in range(24):
        var pi = (i * 7) % len(p)
        assert_equal(got.get(i), expect[pi])


# ---------------------------------------------------------------------------
# 3. The sampling boundary — ONE column, TWO code paths.
# ---------------------------------------------------------------------------


def test_replace_all_distinct_past_sampling_boundary_equals_scalar() raises:
    """5,000 ALL-DISTINCT rows: the memo samples the first 4,096, finds no
    repeats and switches itself OFF.  Rows on both sides of that row are
    served by DIFFERENT code (arena + table, then the plain builder path), and
    nothing else in the suite crosses it."""
    var vals = List[String]()
    for i in range(5000):
        vals.append(String("http://d") + String(i) + String(".example.com/p/") + String(i))
    _assert_column_equals_scalar(vals, List[Int](), Q28_PAT, Q28_REP, String(""))


def test_replace_distinct_then_duplicates_equals_scalar() raises:
    """4,200 all-distinct rows (memo off at 4,096) FOLLOWED by 300 duplicates.

    The duplicates arrive AFTER the switch, so they are answered by the VM
    again.  A disable that leaves the caller still reading arena spans breaks
    exactly here and nowhere earlier."""
    var vals = List[String]()
    for i in range(4200):
        vals.append(String("http://u") + String(i) + String(".example.org/z"))
    var p = _palette()
    for i in range(300):
        vals.append(p[(i * 7) % len(p)])
    _assert_column_equals_scalar(vals, List[Int](), Q28_PAT, Q28_REP, String(""))


def test_replace_small_column_below_enable_threshold_equals_scalar() raises:
    """A 16-row column never arms the memo at all (`n_rows >= 64`).  The
    pre-memo kernel must still be reachable and still be right."""
    _assert_column_equals_scalar(_dup_heavy(16), List[Int](), Q28_PAT, Q28_REP, String(""))


# ---------------------------------------------------------------------------
# 4. The other two arms of the same kernel.
# ---------------------------------------------------------------------------


def test_replace_global_duplicates_equals_scalar() raises:
    """`g` (replace-all) assembles SEVERAL segments per value.  Through the
    arena that is several `extend`s and no `end_value`, which is precisely
    where the mirror can drift from `_replace_into`.  Duplicates make the
    memoised value the one that is emitted."""
    var vals = List[String]()
    var pal = List[String]()
    pal.append(String("a1b22c333d"))
    pal.append(String("nodigits"))
    pal.append(String("1"))
    pal.append(String(""))
    pal.append(String("99x88y77"))
    pal.append(String("z9"))
    for i in range(300):
        vals.append(pal[(i * 5) % len(pal)])
    _assert_column_equals_scalar(
        vals, List[Int](), String("[0-9]+"), String("<\\0>"), String("g")
    )


def test_replace_zero_width_pattern_duplicates_equals_scalar() raises:
    """A pattern that can match EMPTY drives the GlobalReplace empty-match rule
    — the branch `_replace_into_arena` had to copy verbatim.  Duplicates force
    the arena copy to be re-emitted rather than recomputed."""
    var vals = List[String]()
    var pal = List[String]()
    pal.append(String("aaa"))
    pal.append(String("abcabc"))
    pal.append(String(""))
    pal.append(String("b"))
    for i in range(200):
        vals.append(pal[(i * 3) % len(pal)])
    _assert_column_equals_scalar(
        vals, List[Int](), String("a*"), String("-"), String("g")
    )


def test_replace_invalid_template_duplicates_returns_input() raises:
    """An invalid rewrite template short-circuits to "the input row, unchanged"
    for EVERY row and never runs the VM — so the memo must not be armed, and
    the duplicate rows must still be their own input."""
    var vals = _dup_heavy(200)
    var col = _col(vals)
    var gs = split_g_flag(String(""))
    var prog = RegexProgram.compile(Q28_PAT, gs[0])
    # `\9` names a group the pattern does not have.
    var got = eval_regexp_replace(col, prog, String("\\9"), gs[1])
    assert_equal(got.length, len(vals))
    for i in range(len(vals)):
        assert_equal(got.get(i), vals[i])


# ---------------------------------------------------------------------------
# 10. THE MEMO KEY ITSELF — same length, divergence LATE in the subject.
#
# ⭐ WHY THIS EXISTS. `_ReplaceMemo` decides "same
# subject" from the triple (hash, length, bytes), and BOTH the hash and the
# byte comparison were replaced with wide kernels: `_hash_of` strides 32 bytes
# per round (xxHash64) and `find` compares vector-width at a time
# (`bytes_equal`). The defect class a swap like that introduces is not a wrong
# answer on a random column — it is a key comparison that stops short of the
# END of the subject, so two subjects agreeing on every byte but the last
# collide and ONE OF THEM IS EMITTED FOR BOTH.
#
# Every other test in this file uses `_palette`, whose 12 subjects differ
# EARLY and in LENGTH — the two properties that make such a defect invisible.
# The fixtures below are built the other way on purpose: every pair is
# BYTE-IDENTICAL except for one byte, at a chosen offset, with IDENTICAL
# lengths, and the lengths are swept across the 16 / 32 / 64-byte boundaries a
# vector ladder and a 32-byte hash stripe each divide on.
# ---------------------------------------------------------------------------


def _late_divergence_pair(total_len: Int, diff_at_end_offset: Int) raises -> List[String]:
    """Two subjects of EXACTLY `total_len` bytes, matching Q28's pattern,
    identical except for the byte `diff_at_end_offset` bytes from the end of
    the DOMAIN — so the two ANSWERS differ at that same offset.

    Shape: `http://` + <domain of total_len-9 bytes> + `/x`. The domain is
    all ASCII with no `/`, so the capture is the whole domain and the answer
    is exactly the domain."""
    var dom_len = total_len - 9
    if dom_len < 2:
        raise Error("_late_divergence_pair: total_len too small")
    var a = String("")
    for i in range(dom_len):
        a += chr(ord("a") + (i % 26))
    var flip = dom_len - 1 - diff_at_end_offset
    if flip < 0:
        flip = 0
    var b = String("")
    for i in range(dom_len):
        if i == flip:
            # A byte the ladder cannot confuse with the original and that is
            # still a legal domain character (never `/`).
            b += String("Z")
        else:
            b += chr(ord("a") + (i % 26))
    var out = List[String]()
    out.append(String("http://") + a + String("/x"))
    out.append(String("http://") + b + String("/x"))
    return out^


def test_replace_same_length_late_divergence_equals_scalar() raises:
    """Same-length subjects differing in ONE byte, swept across the widths a
    vector compare and a 32-byte hash stripe divide on, each repeated enough
    times to arm the memo and take the HIT arm many times over.

    ⛔ A memo whose key comparison stops at a vector boundary passes every
    other test in this file and fails this one."""
    var vals = List[String]()
    var lens = List[Int]()
    lens.append(12)    # domain 3  — below one 16-byte lane
    lens.append(25)    # domain 16 — exactly one lane
    lens.append(26)    # domain 17 — one lane + 1
    lens.append(41)    # domain 32 — exactly one 32-byte stripe
    lens.append(42)    # domain 33 — one stripe + 1
    lens.append(73)    # domain 64 — two stripes
    lens.append(74)    # domain 65 — two stripes + 1
    lens.append(91)    # domain 82 — the measured ClickBench Q28 mean
    var pool = List[String]()
    for k in range(len(lens)):
        # divergence at the LAST byte of the domain, and 1 byte before it
        var p0 = _late_divergence_pair(lens[k], 0)
        pool.append(p0[0])
        pool.append(p0[1])
        var p1 = _late_divergence_pair(lens[k], 1)
        pool.append(p1[1])
    # 3 * 8 = 24 distinct subjects; 1200 rows at a coprime stride so every
    # subject repeats ~50 times and no repeat is adjacent.
    for i in range(1200):
        vals.append(pool[(i * 7) % len(pool)])
    _assert_column_equals_scalar(vals, List[Int](), Q28_PAT, Q28_REP, String(""))


def test_replace_same_length_late_divergence_answers_are_distinct() raises:
    """THE FIXTURE'S OWN FALSIFIER. If the two subjects of a pair produced the
    SAME answer, the test above would pass against a memo that confused them
    and would be evidence of nothing."""
    var seen = List[String]()
    var lens = List[Int]()
    lens.append(25)
    lens.append(41)
    lens.append(73)
    lens.append(91)
    var gs = split_g_flag(String(""))
    var prog = RegexProgram.compile(Q28_PAT, gs[0])
    for k in range(len(lens)):
        var pr = _late_divergence_pair(lens[k], 0)
        var a0 = regexp_replace_scalar(pr[0], prog, Q28_REP, gs[1])
        var a1 = regexp_replace_scalar(pr[1], prog, Q28_REP, gs[1])
        # both must MATCH (answer != subject) and must differ from each other
        assert_true(a0 != pr[0])
        assert_true(a1 != pr[1])
        assert_true(a0 != a1)
        assert_equal(len(a0.as_bytes()), len(a1.as_bytes()))
        assert_equal(len(pr[0].as_bytes()), lens[k])
        assert_equal(len(pr[1].as_bytes()), lens[k])
        for j in range(len(seen)):
            assert_true(seen[j] != a0)
        seen.append(a0)
        seen.append(a1)


def test_replace_empty_and_one_byte_subjects_equals_scalar() raises:
    """The hash and the compare both have a scalar TAIL. An empty subject
    exercises the zero-length arm of both, and a 1-byte subject the
    minimum-nonzero one; mixing them with long subjects in ONE column means
    the same memo table answers all three widths."""
    var vals = List[String]()
    var pool = List[String]()
    pool.append(String(""))
    pool.append(String("x"))
    pool.append(String("http://a.b/c"))
    pool.append(String("http://www.example.com/a/b/c?q=1"))
    pool.append(String("y"))
    for i in range(400):
        vals.append(pool[(i * 3) % len(pool)])
    _assert_column_equals_scalar(vals, List[Int](), Q28_PAT, Q28_REP, String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
