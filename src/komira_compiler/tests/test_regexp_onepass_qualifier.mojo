# =============================================================================
# ONE-PASS QUALIFICATION.  IT DECIDES A FACT; IT BUILDS NO ENGINE.
# =============================================================================
#
# ⭐ WHY THIS FILE EXISTS.  "ClickBench Q28's pattern plausibly qualifies for
# OnePass" is an INFERENCE walked by hand, because `RE2::is_one_pass_` is a
# private field with no public accessor and RE2's internals are not vendored
# here.  An engine built on an unverified inference is weeks of work that may
# close nothing.  So this file ports the PREDICATE and asks it before any
# engine is written.
#
# ⭐ THE ORACLE, AND IT IS EXTERNAL.  `re2/onepass.cc`'s own header comment
# names eight patterns and states, for each, whether it is one-pass:
#
#     "For example, the regexp /x*yx*/ is one-pass ...
#      On the other hand, /x*x/ is not one-pass ...
#      More examples: /([^ ]*) (.*)/ is one-pass; /(.*) (.*)/ is not.
#      /(\d+)-(\d+)/ is one-pass; /(\d+).(\d+)/ is not. ...
#      /x(y|z)/ is one-pass, but /(xy|xz)/ is not."
#
# Those eight are asserted below.  They are RE2 documenting its OWN predicate,
# so a qualifier that reproduces all eight is validated against something other
# than its author's reasoning -- which is exactly what the hand-walk lacked.
# (google/re2, BSD-3-Clause.  The ALGORITHM of `Prog::IsOnePass` is ported; no
# C++ source is copied.  Copyright 2008 The RE2 Authors.)
#
# ⛔ NO RUNTIME IS TESTED HERE BECAUSE NO RUNTIME EXISTS.  Every assertion is
# over `one_pass_verdict`, a pure function of a compiled `List[Inst]`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.eval.regexp_nfa import (
    ANCHOR_NONE,
    ByteClass,
    Inst,
    ONEPASS_BAD_TARGET,
    ONEPASS_BYTE_CONFLICT,
    ONEPASS_EMPTY_PROGRAM,
    ONEPASS_MULTIPLE_MATCHES,
    ONEPASS_MULTIPLE_PATHS,
    ONEPASS_SLOT_BUDGET,
    OP_JMP,
    OP_MATCH,
    OP_SPLIT,
    RegexProgram,
    classify_start_anchor,
    one_pass_verdict,
)
from komira_core.eval.regexp_functions import (
    regexp_extract_scalar,
    regexp_like_as_like_pattern,
)


# ---------------------------------------------------------------------------
# 1. RE2'S OWN EIGHT.  The external oracle.
# ---------------------------------------------------------------------------


def _assert_one_pass(pattern: String, want: Bool) raises:
    var prog = RegexProgram.compile(pattern, "")
    var v = prog.one_pass()
    assert_equal(
        v.ok,
        want,
        String(
            "pattern ", pattern, ": one_pass_verdict says ", v.ok,
            ", RE2's own documentation says ", want, " -- ", v.describe(),
        ),
    )


def test_re2_documented_x_star_y_x_star_is_one_pass() raises:
    _assert_one_pass("x*yx*", True)


def test_re2_documented_x_star_x_is_not_one_pass() raises:
    _assert_one_pass("x*x", False)


def test_re2_documented_nonspace_then_dot_star_is_one_pass() raises:
    # /([^ ]*) (.*)/ -- the class-then-EXCLUDED-delimiter shape.  This is the
    # shape Q28's `([^/]+)/` has, which is why it is worth pinning separately.
    _assert_one_pass("([^ ]*) (.*)", True)


def test_re2_documented_dot_star_then_dot_star_is_not_one_pass() raises:
    # /(.*) (.*)/ -- `.` admits the space, so the delimiter is ambiguous.
    _assert_one_pass("(.*) (.*)", False)


def test_re2_documented_digits_dash_digits_is_one_pass() raises:
    _assert_one_pass("(\\d+)-(\\d+)", True)


def test_re2_documented_digits_dot_digits_is_not_one_pass() raises:
    _assert_one_pass("(\\d+).(\\d+)", False)


def test_re2_documented_factored_alternation_is_one_pass() raises:
    _assert_one_pass("x(y|z)", True)


def test_re2_documented_unfactored_alternation_is_not_one_pass() raises:
    # /(xy|xz)/ -- both branches consume `x`, so the branch to take is not
    # decided by the byte in hand.  ⭐ THIS IS THE SHAPE THAT DECIDES Q28.
    _assert_one_pass("(xy|xz)", False)


# ---------------------------------------------------------------------------
# 2. THE THREE CONDITIONS, ONE TEST EACH, WITH THE REASON CODE PINNED.
#    A qualifier that rejects for the WRONG reason is not validated by a Bool.
# ---------------------------------------------------------------------------


def test_condition_2_byte_conflict_names_the_byte() raises:
    var prog = RegexProgram.compile("(xy|xz)", "")
    var v = prog.one_pass()
    assert_false(v.ok)
    assert_equal(Int(v.reason), Int(ONEPASS_BYTE_CONFLICT))
    assert_equal(v.detail, ord("x"), String("expected the conflict on 'x': ", v.describe()))


def test_condition_1_two_epsilon_paths_to_one_pc() raises:
    # `(?:^|\b)a`: both alternatives are ZERO-WIDTH, so they converge on the
    # same `CHAR a` with DIFFERENT assertion conditions.  A thread-list engine
    # keeps both; a table with one action per (node, byte) cannot, so RE2 fails
    # the program rather than record either.  ⛔ THE TEST THAT WOULD SILENTLY
    # PASS IF THE PORT PRUNED LIKE `_closure` DOES.
    var prog = RegexProgram.compile("(?:^|\\b)a", "")
    var v = prog.one_pass()
    assert_false(v.ok, String("multi-path program accepted: ", v.describe()))
    assert_equal(Int(v.reason), Int(ONEPASS_MULTIPLE_PATHS))


def test_condition_3_two_matches_from_one_node() raises:
    # Hand-built, because `RegexProgram.compile` always ends `SAVE 1 ; MATCH`
    # with a single MATCH pc -- so through the compiler, two paths to MATCH are
    # always two paths to that SAVE and trip condition (1) first.  Condition (3)
    # is still ported, and this is what reaches it.
    var prog = List[Inst]()
    prog.append(Inst(OP_SPLIT, 1, 2))
    prog.append(Inst(OP_MATCH, 0, 0))
    prog.append(Inst(OP_MATCH, 0, 0))
    var v = one_pass_verdict(prog, List[ByteClass](), 2)
    assert_false(v.ok)
    assert_equal(Int(v.reason), Int(ONEPASS_MULTIPLE_MATCHES))


def test_malformed_and_empty_programs_are_refused_not_accepted() raises:
    var empty = List[Inst]()
    var ve = one_pass_verdict(empty, List[ByteClass](), 2)
    assert_false(ve.ok)
    assert_equal(Int(ve.reason), Int(ONEPASS_EMPTY_PROGRAM))

    var bad = List[Inst]()
    bad.append(Inst(OP_JMP, 99, 0))
    var vb = one_pass_verdict(bad, List[ByteClass](), 2)
    assert_false(vb.ok)
    assert_equal(Int(vb.reason), Int(ONEPASS_BAD_TARGET))


def test_slot_budget_refuses_rather_than_truncating_the_cap_mask() raises:
    # The cap set is a UInt64 bitmask.  A program with more slots than that must
    # be REFUSED, never analysed with the high slots silently dropped -- a
    # dropped slot makes two different capture-write sets compare EQUAL, which
    # turns a real conflict into a false "qualifies".
    var prog = List[Inst]()
    prog.append(Inst(OP_MATCH, 0, 0))
    var v = one_pass_verdict(prog, List[ByteClass](), 128)
    assert_false(v.ok)
    assert_equal(Int(v.reason), Int(ONEPASS_SLOT_BUDGET))


# ---------------------------------------------------------------------------
# 3. ⭐⭐ THE GATE QUESTION: DOES ClickBench Q28'S PATTERN QUALIFY?
# ---------------------------------------------------------------------------


def _q28_pattern() -> String:
    return "^https?://(?:www\\.)?([^/]+)/.*$"


def test_q28_pattern_does_not_qualify_for_one_pass() raises:
    # ⛔ THE ANSWER IS NO, AND THE DESIGN SAID YES.
    #
    # A hand walk of
    # this pattern concluded "plausibly qualifies", checking each
    # construct IN ISOLATION: "`(?:www\.)?` -- same shape: `w` continues,
    # anything else exits -- disjoint".  What that walk could not see is where
    # "anything else exits" LANDS.  It lands on `([^/]+)`, and `w` is in
    # `[^/]`.  So after the second `/` there are two instructions that consume
    # `w`: the literal `w` of `www\.` and the class of group 1.  That is RE2's
    # own `/(xy|xz)/` counterexample, pinned above, spelled with a class.
    #
    # ⇒ RE2 -- and therefore DuckDB, which sets neither `longest_match` nor
    # `posix_syntax` (see the header of `test_regexp_pike_vm_duckdb_oracle`) --
    # does NOT use SearchOnePass for Q28 either.
    var prog = RegexProgram.compile(_q28_pattern(), "")
    var v = prog.one_pass()
    assert_false(v.ok, String("Q28 now QUALIFIES: ", v.describe(), " -- the Stage-0 gate has changed answer, re-read the design before building on it"))
    assert_equal(Int(v.reason), Int(ONEPASS_BYTE_CONFLICT))
    assert_equal(v.detail, ord("w"), String("the conflict is supposed to be on 'w': ", v.describe()))


# ⭐⭐ SO WHAT DOES RE2 ACTUALLY RUN ON Q28?  SearchBitState -- an engine a
# lazy-DFA port would not build.
#
# Read from `re2/re2.cc` and then
# MEASURED against the vendored `duckdb` v1.5.3 binary, which agrees to the BYTE:
#
#   re2.cc:704-707   `^...$` sets BOTH anchors, so `re_anchor` is rewritten to
#                    ANCHOR_BOTH before the engine ladder is entered.
#   re2.cc:825-846   in that arm, with `can_one_pass` FALSE (proved above) and
#                    `ncap > 1` (regexp_replace's `\1` needs group 1):
#                        if (can_bit_state && text.size <= bit_state_text_max_size
#                            && ncap > 1) { skipped_test = true; break; }
#                    -- THE FORWARD DFA IS NEVER CALLED.
#   re2.cc:871-893   `skipped_test` => `subtext1 = subtext` (the WHOLE row, not a
#                    DFA-narrowed span) => `SearchBitState`, anchored, full-match.
#   prog.cc:656-657  `bit_state_text_max_size_ = 256*1024 / list_count_ - 1`.
#                    The design could not pin this constant and said so.
#
# MEASURED, `duckdb` v1.5.3, threads=1, Q28's literal pattern, subject
# `'http://www.example.com/' || repeat('a', N)`, ~20 MB of subject per point:
#
#     subject bytes   12423  12473  12482 | 12483  12493  12523  13023
#     ns per byte      4.54   4.42   4.44 |  5.07  13.49  12.85  12.96
#
# The step is at 12,482 -> 12,483 EXACTLY, which is `262144 / 21 - 1` -- so
# `list_count_` is 21 for this program and RE2's `<=` is inclusive.  Below the
# cutoff BitState; above it, BitState is refused and SearchNFA runs (3x).
#
# AND THE SIGN INVERTS ON A NON-MATCHING SUBJECT, which is what proves the DFA
# is SKIPPED rather than merely fast.  Same pattern, subject
# `'http://www.example.com' || repeat('a', N)` (passes RE2's required literal
# prefix `http`, can never match -- no `/` closes `([^/]+)`):
#
#     subject bytes   12422  12481 | 12492  12622  13022  16022
#     ns per byte     12.24  12.03 |  0.90   0.90   0.80   1.02
#
# Below the cutoff the DFA is skipped and BitState backtracks the whole 12 KB
# before failing (12 ns/byte).  Above it the skip does not fire, the DFA runs,
# rejects in one linear pass and no capture engine is entered at all (0.9
# ns/byte).  Same boundary byte, opposite direction -- exactly what `skipped_test`
# says, and not something a DFA-first ladder could produce.
#
# ⇒ EVERY ClickBench row (max observed 2,739 B) is far below 12,482, so Q28's
#   DuckDB path is: required-prefix memcmp (rejects 0% -- already measured), then
#   BitState over the whole row.  No OnePass.  No lazy DFA.
# ⚠ THOSE ns/byte FIGURES ARE NOT COMPARABLE TO THE 26.85 ns/byte ClickBench
#   number.  Degenerate all-`a` subjects, one thread, a different row shape; they
#   are a BOUNDARY LOCATOR, not a performance measurement.
# ⚠ AND IT IS THE CAPTURE CALLS ONLY.  A boolean `regexp_matches` reaches RE2
#   with `nsubmatch == 0` => `ncap == 0`, the skip branch requires `ncap > 1`,
#   so the DFA DOES run.  The design's Stage 3 (a forward DFA for
#   `regexp_like` / `regexp_full_match`) is confirmed as what RE2 does there.


def test_q28_without_the_optional_www_group_would_qualify() raises:
    # THE CONTROL.  Same pattern, `(?:www\.)?` deleted: it qualifies.  That
    # isolates the disqualifier to one construct and proves the qualifier is not
    # just rejecting everything Q28-shaped.
    # ⚠ NOT A PROPOSED REWRITE: dropping the optional group CHANGES GROUP 1
    # (it would then include the `www.`), so it is a different query.
    var prog = RegexProgram.compile("^https?://([^/]+)/.*$", "")
    var v = prog.one_pass()
    assert_true(v.ok, String("the control pattern should be one-pass: ", v.describe()))


# ---------------------------------------------------------------------------
# 4. THE CENSUS -- what fraction of this tree's regexp patterns qualify.
#    Every pattern literal reachable from a `RegexProgram.compile` call site in
#    the repo's regexp tests, plus the two bench-only ones.  Extracted
#    mechanically; the point is that it is NOT a curated sample.
# ---------------------------------------------------------------------------


def _corpus() -> List[String]:
    var v = List[String]()
    v.append("((a)(b))(c)")
    v.append("((a)|(b))+")
    v.append("()")
    v.append("(?:a*)*")
    v.append("(?<=foo)bar")
    v.append("(?<year>\\d+)")
    v.append("(?P<")
    v.append("(?P<1bad>a)")
    v.append("(?P<>a)")
    v.append("(?P<dup>a)(?P<dup>b)")
    v.append("(?P<name>a)")
    v.append("(?P<y>\\d+)-(?P<m>\\d+)-(?P<d>\\d+)")
    v.append("(?P<year>\\d+)-(?P<month>\\d+)")
    v.append("(?P<year>\\d+)-(?P<month>\\d+)-(?P<day>\\d+)")
    v.append("(?Pname>a)")
    v.append("([^/]+)")
    v.append("([a-c]+)(.*)")
    v.append("([a-z])([0-9])")
    v.append("(\\d+)-(\\d+)")
    v.append("(\\d{4})-(\\d{2})-(\\d{2})")
    v.append("(\\s+)")
    v.append("(\\w+)$")
    v.append("(\\w+):(?P<val>\\d+)")
    v.append("(^a)|(b)")
    v.append("(a(b(c)?)?)")
    v.append("(a*)")
    v.append("(a*)(b*)")
    v.append("(a+?)(a*)")
    v.append("(ab|a)(b?)")
    v.append("(a{2,3})(a*)")
    v.append("(a|ab)(c|bcd)")
    v.append("(a|b)+")
    v.append(",")
    v.append("X")
    v.append("[0-9]")
    v.append("[0-9]+")
    v.append("\\A(a*)")
    v.append("\\b")
    v.append("\\d+")
    v.append("^(\\w+)")
    v.append("^(a+)(b*)$")
    v.append("^a")
    v.append("^a.*z$")
    v.append("^abc")
    v.append("^a|b")
    v.append("^https?://(?:www\\.)?([^/]+)/.*$")
    v.append("abc")
    v.append("at")
    v.append("foo")
    # The two benchmark patterns that are not in a test file: ClickBench Q28's
    # live pattern and the ZQXJ "matches nothing" control
    # (`test_regexp_anchor_seed_and_reuse`).
    v.append("^ZQXJ://(?:www\\.)?([^/]+)/.*$")
    v.append("ZQXJ://(?:www\\.)?([^/]+)/.*$")
    return v^


struct _CensusRow(Movable, Copyable):
    var ok: Bool
    var anchored: Bool
    var pike: Bool          # the LIKE fast path refuses it => the Pike VM runs
    var note: String

    def __init__(out self, ok: Bool, anchored: Bool, pike: Bool, var note: String):
        self.ok = ok
        self.anchored = anchored
        self.pike = pike
        self.note = note^

    def copy(self) -> Self:
        return Self(self.ok, self.anchored, self.pike, self.note.copy())


def _analyse(pat: String) raises -> _CensusRow:
    var prog = RegexProgram.compile(pat, "")
    var v = prog.one_pass()
    var anchored = prog.start_anchor != ANCHOR_NONE
    var like = regexp_like_as_like_pattern(prog)
    var pike = True
    if like:
        pike = False
    return _CensusRow(v.ok, anchored, pike, v.describe())


def test_census_of_the_repo_regexp_corpus() raises:
    var pats = _corpus()
    var n_total = len(pats)
    var n_uncompilable = 0
    var n_qualify = 0
    var n_anchored = 0
    var n_anchored_qualify = 0
    var n_runs_pike_vm = 0
    var n_runs_pike_vm_qualify = 0
    var detail = String("")
    for i in range(n_total):
        var pat = pats[i]
        try:
            var row = _analyse(pat)
            if row.ok:
                n_qualify += 1
            if row.anchored:
                n_anchored += 1
                if row.ok:
                    n_anchored_qualify += 1
            if row.pike:
                n_runs_pike_vm += 1
                if row.ok:
                    n_runs_pike_vm_qualify += 1
            detail += String(
                "  ", "OK " if row.ok else "no ", pat, "  [",
                "anchored" if row.anchored else "unanchored", ", ",
                "pike" if row.pike else "LIKE-fastpath", "]  ", row.note, "\n",
            )
        except:
            n_uncompilable += 1
            detail += String("  -- ", pat, "  [does not compile]\n")

    var summary = String(
        "\nREGEXP ONE-PASS CENSUS\n",
        "  corpus patterns           ", n_total, "\n",
        "  uncompilable (on purpose) ", n_uncompilable, "\n",
        "  compiled                  ", n_total - n_uncompilable, "\n",
        "  QUALIFY for one-pass      ", n_qualify, "\n",
        "  start-anchored            ", n_anchored, "\n",
        "  anchored AND qualify      ", n_anchored_qualify, "\n",
        "  run the Pike VM today     ", n_runs_pike_vm, "\n",
        "  of those, qualify         ", n_runs_pike_vm_qualify, "\n",
        detail,
    )

    # ⛔ PINNED AS MEASURED.  These are the Stage-0 answer to "is OnePass a Q28
    # fix or a product-wide one".  A change in any of them is a finding: either
    # the corpus moved or the qualifier did, and both need reading, not a bump.
    assert_equal(n_total, 51, summary)
    assert_equal(n_uncompilable, 6, summary)
    assert_equal(n_qualify, 35, summary)
    assert_equal(n_anchored, 8, summary)
    assert_equal(n_anchored_qualify, 5, summary)
    assert_equal(n_runs_pike_vm, 40, summary)
    assert_equal(n_runs_pike_vm_qualify, 30, summary)


# ---------------------------------------------------------------------------
# 5. QUESTION (c): IS THE DIFFERENTIAL ORACLE COMPARING LIKE WITH LIKE?
# ---------------------------------------------------------------------------
#
# The design flagged ONE item as "load-bearing and unverified": does DuckDB
# override RE2's `longest_match` / `posix_syntax` defaults?  If it set
# `longest_match(true)`, our leftmost-FIRST engine would already disagree with
# the DuckDB-generated oracle in `test_regexp_pike_vm_duckdb_oracle` on every
# ambiguous alternation, today, independent of any port.
#
# ANSWERED TWO WAYS,
#   SOURCE  duckdb v1.5.3 `src/function/scalar/string/regexp.cpp` +
#           `regexp/regexp_util.cpp`: the ONLY `RE2::Options` setters called
#           anywhere are `set_log_errors(false)`, `set_case_sensitive`,
#           `set_literal` and `set_dot_nl`.  Neither `set_longest_match` nor
#           `set_posix_syntax` is called at all, so RE2's documented defaults
#           (`longest_match_(false)`, `posix_syntax_(false)`) stand.
#   MEASURED against the `duckdb` v1.5.3 binary vendored in this repo's pixi
#           env:  regexp_extract('ab','a|ab') -> 'a'  (leftmost-LONGEST would
#           be 'ab'), regexp_extract('ab','a*|ab') -> 'a', and `\d` / `\w` /
#           `a+?` all work (posix_syntax(true) would reject the Perl classes
#           and the non-greedy quantifier).
#
# ⇒ Leftmost-FIRST, Perl syntax, on both sides.  The oracle IS like-for-like.
# This test pins OUR half of that equality, so a change of match semantics here
# reds against a recorded DuckDB answer rather than drifting silently.


def test_our_engine_is_leftmost_first_like_duckdbs_re2_default() raises:
    # Each expected value was read from `duckdb` v1.5.3 .
    assert_equal(regexp_extract_scalar("ab", RegexProgram.compile("a|ab", ""), 0), "a")
    assert_equal(regexp_extract_scalar("ab", RegexProgram.compile("ab|a", ""), 0), "ab")
    assert_equal(regexp_extract_scalar("ab", RegexProgram.compile("a*|ab", ""), 0), "a")
    assert_equal(regexp_extract_scalar("aaa", RegexProgram.compile("(a|aa)+", ""), 0), "aaa")
    assert_equal(regexp_extract_scalar("aaa", RegexProgram.compile("a+?", ""), 0), "a")
    assert_equal(regexp_extract_scalar("xabc", RegexProgram.compile("(a|ab)(c|bc)", ""), 1), "a")



def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
