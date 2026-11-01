# =============================================================================
# REGEXP ANCHOR-SEED + SCRATCH-REUSE — the correctness floor for Fix B/Fix A.
# =============================================================================
#
# ⛔ WHY THIS FILE EXISTS.  Two perf changes were landed on the Pike VM in
# `komira_column_kernels/regexp_nfa.mojo`:
#
#   FIX B  — the doomed-seed elision.  `_run` used to seed a fresh start thread
#            at EVERY byte position unconditionally; the `^` / `\A` was only
#            discovered one epsilon-step later, after the seed had already
#            allocated `init_slots`, `stack_pc`, `stack_slots` and a SAVE-copy
#            of the slot vector.  `RegexProgram.start_anchor` now classifies the
#            compiled program and `_run` seeds only where the anchor CAN hold.
#   FIX A  — the allocator/reuse pass: flat slot stacks, a generation-stamped
#            `seen` set, no `List[Int]` per thread per byte position.
#
# ⛔⛔ FIX B MOVES *WHERE THREADS ARE SEEDED*.  An off-by-one there silently
# changes WHICH MATCH IS FOUND — not whether the program crashes.  Every
# assertion below is a semantic pin, and the anchor-classification table is the
# falsifier for the analysis itself: a classifier that says "anchored" for a
# pattern with one unanchored alternation branch would make `^a|b` stop
# matching `"xb"`, and `test_anchor_class_half_anchored_alternation_is_none`
# is what reds.
#
# Oracle: DuckDB 1.x / RE2 semantics as already pinned by the sibling files
# `test_regexp_correctness.mojo`, `test_regexp_replace.mojo`,
# `test_regexp_extras.mojo` and `test_regexp_match_family.mojo` — those four
# are the FLOOR, this file is the delta.
#
# Dialect note pinned here (checked against the compiler, not assumed):
#   `^` compiles to ASSERT_BOL under the `m` flag and ASSERT_BOS otherwise;
#   `\A` is ALWAYS ASSERT_BOS.  `(?m)` / `(?m:...)` toggle it INSIDE the
#   pattern, so the classification must read the PROGRAM, never the text.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_column_kernels.regexp_nfa import (
    RegexProgram,
    RegexScratch,
    REGEX_ENGINE_PIKE,
    REGEX_ENGINE_BITSTATE,
    ANCHOR_NONE,
    ANCHOR_BOS,
    ANCHOR_BOL,
)
from komira_column_kernels.regexp_functions import (
    _str_bytes,
    regexp_replace_scalar,
    regexp_like_scalar,
    regexp_extract_scalar,
    regexp_count_scalar,
    regexp_instr_scalar,
    split_g_flag,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _rr(subject: String, pattern: String, replacement: String, flags: String = "") raises -> String:
    var gsplit = split_g_flag(flags)
    var prog = RegexProgram.compile(pattern, gsplit[0])
    return regexp_replace_scalar(subject, prog, replacement, gsplit[1])


def _like(subject: String, pattern: String, flags: String = "") raises -> Bool:
    return regexp_like_scalar(subject, RegexProgram.compile(pattern, flags))


def _extract(subject: String, pattern: String, group: Int, flags: String = "") raises -> String:
    return regexp_extract_scalar(subject, RegexProgram.compile(pattern, flags), group)


def _count(subject: String, pattern: String, flags: String = "") raises -> Int:
    return regexp_count_scalar(subject, RegexProgram.compile(pattern, flags))


def _anchor(pattern: String, flags: String = "") raises -> Int:
    return Int(RegexProgram.compile(pattern, flags).start_anchor)


def _span(subject: String, pattern: String, flags: String = "") raises -> Tuple[Int, Int]:
    var prog = RegexProgram.compile(pattern, flags)
    var m = prog.find(_str_bytes(subject))
    if not m.matched:
        return (-1, -1)
    return (m.start, m.end)


# ---------------------------------------------------------------------------
# 1. THE CLASSIFIER ITSELF.  This is the falsifier for Fix B's analysis.
# ---------------------------------------------------------------------------


def test_anchor_class_plain_caret_is_bos() raises:
    assert_equal(_anchor("^abc"), Int(ANCHOR_BOS))
    assert_equal(_anchor(r"\Aabc"), Int(ANCHOR_BOS))
    # The Q28 shape.
    assert_equal(_anchor(r"^https?://(?:www\.)?([^/]+)/.*$"), Int(ANCHOR_BOS))


def test_anchor_class_multiline_caret_is_bol() raises:
    assert_equal(_anchor("^abc", "m"), Int(ANCHOR_BOL))
    # Inline flag: the classification must read the PROGRAM, not the text.
    assert_equal(_anchor("(?m)^abc"), Int(ANCHOR_BOL))
    # `\A` is absolute even under `m`.
    assert_equal(_anchor(r"\Aabc", "m"), Int(ANCHOR_BOS))


def test_anchor_class_unanchored_is_none() raises:
    assert_equal(_anchor("abc"), Int(ANCHOR_NONE))
    assert_equal(_anchor(".*"), Int(ANCHOR_NONE))
    assert_equal(_anchor(""), Int(ANCHOR_NONE))


def test_anchor_class_end_anchors_are_not_start_anchors() raises:
    # `$` / `\z` pin the END.  Treating them as a start anchor would make
    # `abc$` stop matching anywhere but offset 0.
    assert_equal(_anchor("abc$"), Int(ANCHOR_NONE))
    assert_equal(_anchor(r"abc\z"), Int(ANCHOR_NONE))
    assert_equal(_anchor("$"), Int(ANCHOR_NONE))


def test_anchor_class_word_boundary_is_not_a_start_anchor() raises:
    # `\b` is a zero-width assert that is NOT position-0-only.
    assert_equal(_anchor(r"\babc"), Int(ANCHOR_NONE))
    assert_equal(_anchor(r"\Babc"), Int(ANCHOR_NONE))


def test_anchor_class_half_anchored_alternation_is_none() raises:
    # ⛔ THE ONE THAT MATTERS.  One unanchored branch means the program may
    # start anywhere.  All four spellings.
    assert_equal(_anchor("^a|b"), Int(ANCHOR_NONE))
    assert_equal(_anchor("b|^a"), Int(ANCHOR_NONE))
    assert_equal(_anchor("(?:^a|b)"), Int(ANCHOR_NONE))
    assert_equal(_anchor("(^a)|b"), Int(ANCHOR_NONE))


def test_anchor_class_fully_anchored_alternation_is_anchored() raises:
    assert_equal(_anchor("^a|^b"), Int(ANCHOR_BOS))
    assert_equal(_anchor(r"^a|\Ab"), Int(ANCHOR_BOS))
    # Mixed kinds must degrade to the WEAKER rule (BOL seeds a superset of BOS).
    assert_equal(_anchor(r"(?m)^a|\Ab"), Int(ANCHOR_BOL))


def test_anchor_class_optional_anchor_is_none() raises:
    # `(^)?a` and `(^a)*b` can both match with the anchor skipped entirely.
    assert_equal(_anchor("(^)?a"), Int(ANCHOR_NONE))
    assert_equal(_anchor("(^a)*b"), Int(ANCHOR_NONE))
    assert_equal(_anchor("^?a"), Int(ANCHOR_NONE))


def test_anchor_class_anchor_behind_a_group_or_save_is_anchored() raises:
    # Epsilon-only prefixes (SAVE / JMP / SPLIT with both arms anchored) must
    # not defeat the analysis.
    assert_equal(_anchor("(^a)b"), Int(ANCHOR_BOS))
    assert_equal(_anchor("(?:^a)b"), Int(ANCHOR_BOS))
    assert_equal(_anchor("^(a)"), Int(ANCHOR_BOS))
    assert_equal(_anchor("^(?:a|b)"), Int(ANCHOR_BOS))


def test_anchor_class_bare_anchor_is_anchored() raises:
    # A program that is nothing but the anchor: SAVE0 ; ASSERT ; SAVE1 ; MATCH.
    assert_equal(_anchor("^"), Int(ANCHOR_BOS))
    assert_equal(_anchor("^", "m"), Int(ANCHOR_BOL))


# ---------------------------------------------------------------------------
# 2. SEMANTICS — anchored.  What the elision must not change.
# ---------------------------------------------------------------------------


def test_anchored_match_at_position_zero() raises:
    assert_true(_like("abc", "^abc"))
    assert_equal(_span("abcdef", "^abc"), (0, 3))
    assert_equal(_span("abcdef", r"\Aabc"), (0, 3))


def test_anchored_no_match_when_not_at_zero() raises:
    assert_false(_like("xabc", "^abc"))
    assert_false(_like("xabc", r"\Aabc"))
    assert_equal(_span("xabc", "^abc"), (-1, -1))


def test_anchored_match_reaching_the_final_byte() raises:
    assert_equal(_span("abc", "^abc"), (0, 3))
    assert_equal(_span("abc", "^a.*c$"), (0, 3))
    assert_equal(_span("abc", r"^abc\z"), (0, 3))


def test_anchored_empty_subject() raises:
    assert_true(_like("", "^"))
    assert_true(_like("", r"^\z"))
    assert_false(_like("", "^a"))
    assert_equal(_span("", "^"), (0, 0))


def test_anchored_zero_length_match_at_zero() raises:
    assert_equal(_span("abc", "^"), (0, 0))
    assert_equal(_span("abc", "^a*"), (0, 1))
    assert_equal(_span("bbb", "^a*"), (0, 0))


def test_unanchored_still_scans_every_position() raises:
    # The control for the elision: a program the classifier calls NONE must
    # still be seeded everywhere.
    assert_equal(_span("xxabc", "abc"), (2, 5))
    assert_equal(_span("xxabc", "abc$"), (2, 5))
    assert_equal(_span("xxabc", "^a|bc"), (3, 5))
    assert_equal(_span("xxabc", "(^a)|bc"), (3, 5))


# ---------------------------------------------------------------------------
# 3. SEMANTICS — multiline.  `^` after a newline MUST still seed.
# ---------------------------------------------------------------------------


def test_multiline_caret_matches_after_newline() raises:
    assert_true(_like("a\nb", "^b", "m"))
    assert_equal(_span("a\nb", "^b", "m"), (2, 3))
    assert_true(_like("a\nb", "(?m)^b"))
    # ... and does NOT without the flag.
    assert_false(_like("a\nb", "^b"))


def test_multiline_caret_at_the_very_end_after_a_trailing_newline() raises:
    # Position 2 == n: a line start that is also end-of-subject.  `\n` at the
    # end of the subject IS a line start at offset n, and the seed filter must
    # still fire there.
    assert_equal(_span("a\n", "^", "m"), (0, 0))
    assert_equal(_rr("a\n", "^", ">", "gm"), ">a\n>")
    assert_equal(_rr("a\nb\nc", "^", ">", "gm"), ">a\n>b\n>c")


def test_PREEXISTING_find_all_in_duplicates_a_zero_width_match_after_a_skip() raises:
    # ⚠⚠ PRE-EXISTING DEFECT, PINNED AS-OBSERVED — NOT introduced by the anchor
    # elision and NOT fixed by it.  `find_all_in` advances `pos` to `m.end` and
    # then searches again from there, so a ZERO-WIDTH match found at an offset
    # STRICTLY AHEAD of `pos` is re-found at that same offset on the next
    # iteration and emitted twice.  `_replace_one` does not have the bug — it
    # carries RE2's "an empty match immediately after the previous match is
    # skipped" rule, which is why the `regexp_replace` assertions above give the
    # right answer while `regexp_count` over the same input does not.
    #
    # Reached through `regexp_count` / `regexp_extract_all` / `regexp_match`
    # only, and only for a zero-width match whose offset is > the previous
    # `pos`.  ⛔ This pin exists so the elision cannot silently CHANGE the
    # number either -- fixing it is separate work with its own DuckDB oracle.
    assert_equal(_count("a\n", "^", "m"), 3)      # DuckDB/RE2 would say 2
    assert_equal(_count("a\nb\nc", "^", "m"), 5)  # DuckDB/RE2 would say 3
    # No skip -> no duplication: every line start is exactly one byte on.
    assert_equal(_count("\n\n", "^", "m"), 3)
    # And a NON-zero-width match is unaffected at any spacing.
    assert_equal(_count("a\nb\nc", "^.", "m"), 3)


def test_multiline_replace_all_hits_every_line_start() raises:
    assert_equal(_rr("a\nb\nc", "^", ">", "gm"), ">a\n>b\n>c")
    assert_equal(_rr("a\nb", "^(.)", "[\\1]", "gm"), "[a]\n[b]")
    # Non-multiline: only the first line start.
    assert_equal(_rr("a\nb\nc", "^", ">", "g"), ">a\nb\nc")


def test_multiline_consecutive_newlines() raises:
    assert_equal(_count("\n\n", "^", "m"), 3)
    assert_equal(_rr("\n\n", "^", "X", "gm"), "X\nX\nX")


def test_bos_anchor_ignores_newlines_even_under_m() raises:
    assert_equal(_count("a\nb", r"\A", "m"), 1)
    assert_false(_like("a\nb", r"\Ab", "m"))


# ---------------------------------------------------------------------------
# 4. SEMANTICS — global / find_all over an anchored program.
# ---------------------------------------------------------------------------


def test_anchored_replace_all_fires_exactly_once() raises:
    # `^a` under `g` must replace ONE leading `a`, not three.
    assert_equal(_rr("aaa", "^a", "X", "g"), "Xaa")
    assert_equal(_count("aaa", "^a"), 1)
    assert_equal(_count("aaa", "a"), 3)


def test_anchored_find_from_past_zero_finds_nothing() raises:
    var prog = RegexProgram.compile("^a", "")
    var subj = _str_bytes("aaa")
    assert_true(prog.find_from(subj, 0).matched)
    assert_false(prog.find_from(subj, 1).matched)
    assert_false(prog.find_from(subj, 2).matched)
    assert_false(prog.find_from(subj, 3).matched)
    # Out of range start is still a clean no-match, never a trap.
    assert_false(prog.find_from(subj, 4).matched)


def test_anchored_instr_and_count() raises:
    assert_equal(_count("abcabc", "^abc"), 1)
    assert_equal(regexp_instr_scalar("abcabc", RegexProgram.compile("^abc", "")), 1)
    assert_equal(regexp_instr_scalar("xabc", RegexProgram.compile("^abc", "")), 0)


# ---------------------------------------------------------------------------
# 5. CAPTURES — `\1` is what Q28's rewrite uses.
# ---------------------------------------------------------------------------


def test_q28_shape_capture_and_rewrite() raises:
    var pat = r"^https?://(?:www\.)?([^/]+)/.*$"
    assert_equal(_rr("http://example.com/a/b", pat, r"\1"), "example.com")
    assert_equal(_rr("https://www.example.com/x", pat, r"\1"), "example.com")
    assert_equal(_extract("https://www.example.com/x", pat, 1), "example.com")
    # No match -> input returned unchanged (DuckDB/RE2 behaviour).
    assert_equal(_rr("ftp://example.com/x", pat, r"\1"), "ftp://example.com/x")
    # `http:%2F%2F...` — starts with the literal, never matches.  This is 18.2%
    # of Q28's real rows.
    assert_equal(_rr("http:%2F%2Fexample.com", pat, r"\1"), "http:%2F%2Fexample.com")


def test_anchored_capture_spans_and_nonparticipating_groups() raises:
    assert_equal(_rr("2026-09-18", r"^(\d+)-(\d+)-(\d+)$", r"\3/\2/\1"), "18/09/2026")
    # Group 2 does not participate -> empty substitution.
    assert_equal(_rr("a", "^(a)|(b)", r"[\1][\2]"), "[a][]")
    assert_equal(_extract("a", "^(a)(b)?", 2), "")


def test_anchored_leftmost_first_priority_is_preserved() raises:
    # Greedy `a*` takes all three; the second group gets nothing.
    assert_equal(_rr("aaa", "^(a*)(a*)$", r"<\1|\2>"), "<aaa|>")
    # Non-greedy.
    assert_equal(_rr("aaa", "^(a*?)(a*)$", r"<\1|\2>"), "<|aaa>")
    # Alternation order, both branches anchored.
    assert_equal(_rr("ab", "^ab|^a", "X"), "X")
    assert_equal(_rr("ab", "^a|^ab", "X"), "Xb")


# ---------------------------------------------------------------------------
# 6. UTF-8 — Q28's data is not ASCII.  The VM is byte-oriented; a seed elision
#    that mis-handled a continuation byte would corrupt the output.
# ---------------------------------------------------------------------------


def test_utf8_multibyte_anchored() raises:
    # A REAL Q28 row shape.
    assert_true(_like("доп_приборы", "^доп"))
    assert_equal(_rr("доп_приборы", "^доп_(.*)$", r"\1"), "приборы")
    assert_equal(_extract("доп_приборы", "^(доп)_", 1), "доп")
    assert_false(_like("x доп_приборы", "^доп"))


def test_utf8_multibyte_unanchored_and_spans_are_byte_offsets() raises:
    # `доп` is 6 bytes; the match starts after "x " -> byte 2.
    assert_equal(_span("x доп", "доп"), (2, 8))
    assert_equal(_rr("a доп b доп c", "доп", "X", "g"), "a X b X c")


def test_utf8_anchored_replace_all_does_not_split_a_codepoint() raises:
    # `^` under `gm` inserts at line starts only — never mid-codepoint.
    assert_equal(_rr("доп\nприборы", "^", ">", "gm"), ">доп\n>приборы")
    assert_equal(_rr("доп", "^", ">", "g"), ">доп")


def test_utf8_dot_is_a_byte_and_that_is_unchanged() raises:
    # PINNED AS-IS, not asserted as desirable: the VM is byte-oriented, so `.`
    # matches one BYTE.  A two-byte cyrillic letter is two `.`s.
    assert_equal(_span("д", "^.."), (0, 2))
    assert_false(_like("д", r"^.\z"))


# ---------------------------------------------------------------------------
# 7. COST PINS — the RED/GREEN for Fix B and Fix A, by COUNTING.
#
#    Nothing below reads a clock.  The VM carries witness counters (see
#    `_ThreadList` / `BitStateScratch`): seeds, threads stepped, byte positions
#    visited, heap-block events.  A cost regression changes those counts, and
#    the counts are the same on every machine, loaded or idle.
# ---------------------------------------------------------------------------


def _letters(n: Int, modulus: Int) -> List[UInt8]:
    var subj = List[UInt8](capacity=n)
    for i in range(n):
        subj.append(UInt8(ord("a") + (i % modulus)))
    return subj^


struct _Counts(Copyable, Movable):
    var seeds: Int
    var steps: Int
    var positions: Int

    def __init__(out self, seeds: Int, steps: Int, positions: Int):
        self.seeds = seeds
        self.steps = steps
        self.positions = positions


def _pike_counts(pattern: String, flags: String, subject: List[UInt8]) raises -> _Counts:
    """Run a fresh Pike VM over `subject` (no match allowed) and read its witness."""
    var prog = RegexProgram.compile(pattern, flags)
    var sc = RegexScratch()
    var m = prog.find_from_with_engine(Span(subject), 0, sc, REGEX_ENGINE_PIKE)
    if m.matched:
        raise Error("regexp cost pin: pattern must match NOTHING")
    return _Counts(sc.vm_seeds(), sc.vm_steps(), sc.vm_positions())


def _bitstate_counts(pattern: String, flags: String, subject: List[UInt8]) raises -> _Counts:
    """Same, on the BitState engine: seeds = start positions tried, steps =
    (pc, position) states visited."""
    var prog = RegexProgram.compile(pattern, flags)
    var sc = RegexScratch()
    var m = prog.find_from_with_engine(Span(subject), 0, sc, REGEX_ENGINE_BITSTATE)
    if m.matched:
        raise Error("regexp cost pin: pattern must match NOTHING")
    return _Counts(sc.bits.seeds, sc.bits.visits, 0)


def test_anchored_no_match_seeds_one_thread_unanchored_seeds_every_byte() raises:
    # ⛔ A RED FOR FIX B.  Before the doomed-seed elision an anchored program
    # was seeded at every byte position and only discovered `^` could not hold
    # one epsilon-step later, so a non-matching anchored search cost as much as
    # an unanchored one.  After it, the anchored search seeds ONLY where the
    # anchor can hold.  Counted on both engines, at two subject lengths: the
    # anchored counts are the same at 1,024 and 32,768 bytes (O(1)), the
    # unanchored ones are exactly one seed per byte position (O(n)).  On the
    # Pike VM the one-seed count is the seed guard AND the skip-ahead that
    # already stops an anchored program after its first position, so the Pike
    # numbers pin them together; BitState's seed count pins its own guard alone.
    var small = _letters(1024, 23)
    var big = _letters(32768, 23)
    var anch = "^ZQXJ://[^/]+/"
    var unanch = "ZQXJ://[^/]+/"

    var pa_small = _pike_counts(anch, "", small)
    var pa_big = _pike_counts(anch, "", big)
    assert_equal(pa_big.seeds, 1, "anchored Pike search must seed exactly once")
    assert_equal(pa_big.positions, 1, "anchored Pike search must visit exactly one position")
    assert_equal(pa_big.seeds, pa_small.seeds, "anchored seeds depend on subject length")
    assert_equal(pa_big.steps, pa_small.steps, "anchored steps depend on subject length")
    assert_equal(pa_big.positions, pa_small.positions, "anchored positions depend on subject length")
    assert_true(pa_big.steps < 8, String("anchored Pike search stepped ", pa_big.steps, " threads"))

    var pu = _pike_counts(unanch, "", big)
    assert_equal(pu.seeds, 32768 + 1, "unanchored Pike search seeds one thread per byte position")
    assert_equal(pu.positions, 32768 + 1)
    assert_true(pu.steps >= 32768, String("unanchored Pike stepped only ", pu.steps, " threads"))

    var ba_small = _bitstate_counts(anch, "", small)
    var ba_big = _bitstate_counts(anch, "", big)
    assert_equal(ba_big.seeds, 1, "anchored BitState search must try exactly one start")
    assert_equal(ba_big.seeds, ba_small.seeds)
    assert_equal(ba_big.steps, ba_small.steps, "anchored BitState visits depend on subject length")
    assert_true(ba_big.steps < 8, String("anchored BitState visited ", ba_big.steps, " states"))

    var bu = _bitstate_counts(unanch, "", big)
    assert_equal(bu.seeds, 32768 + 1, "unanchored BitState tries every start position")
    assert_true(bu.steps >= 32768, String("unanchored BitState visited only ", bu.steps, " states"))


def test_single_literal_search_steps_an_exact_number_of_threads() raises:
    # An absolute pin, so the step counter itself is accountable: a counter
    # that double-counts or never moves cannot pass a flatness comparison alone.
    var prog = RegexProgram.compile("a", "")
    var sc = RegexScratch()
    var subj = List[UInt8]()
    subj.append(UInt8(ord("a")))
    var m = prog.find_from_with_engine(Span(subj), 0, sc, REGEX_ENGINE_PIKE)
    assert_true(m.matched)
    assert_equal(sc.vm_seeds(), 2, "seeded at 0 and at 1 (no match yet when position 1 is seeded)")
    assert_equal(sc.vm_positions(), 2, "positions 0 and 1")
    assert_equal(sc.vm_steps(), 2, "threads stepped for `a` on `a`")


def test_multiline_caret_seeds_once_per_line_start() raises:
    # `^` under `(?m)` can hold at position 0 and after each `\n`, so a
    # 5-line subject is seeded exactly 5 times -- not once per byte.
    var line = 100
    var subj = List[UInt8]()
    for k in range(5):
        if k > 0:
            subj.append(UInt8(10))
        for i in range(line):
            subj.append(UInt8(ord("a") + (i % 23)))
    var pike = _pike_counts("(?m)^ZQXJ://[^/]+/", "", subj)
    assert_equal(pike.seeds, 5, "BOL-anchored Pike search must seed once per line start")
    assert_equal(pike.positions, 5, "BOL-anchored Pike search must visit only line starts")
    var bit = _bitstate_counts("(?m)^ZQXJ://[^/]+/", "", subj)
    assert_equal(bit.seeds, 5, "BOL-anchored BitState search must try once per line start")


def _assert_epsilon_closure_is_allocation_free(pattern: String, min_steps_per_byte: Int) raises:
    """A warm scratch runs `pattern` over 512 and then 4,096 bytes and must
    not grow, rebuild or re-fill anything, whatever the subject length."""
    var small = 512
    var large = 4096
    var prog = RegexProgram.compile(pattern, "")
    var sc = RegexScratch()
    var s1 = _letters(small, 16)
    var s8 = _letters(large, 16)

    # Cold call: the witness must be live (it must register the first growth),
    # or a zero below would prove nothing.
    assert_false(prog.is_match_with(Span(s1), sc))
    assert_true(sc.vm_grows() > 0, "the grow witness did not register the cold call's growth")
    var cap_warm = sc.vm_capacity()
    assert_true(cap_warm[3] > 0, "the closure slot stack was never used")

    var g0 = sc.vm_grows()
    var gen0 = sc.vm_generation()
    var steps0 = sc.vm_steps()
    assert_false(prog.is_match_with(Span(s1), sc))
    var g1 = sc.vm_grows()
    var gen1 = sc.vm_generation()
    var steps1 = sc.vm_steps()
    assert_false(prog.is_match_with(Span(s8), sc))
    var g2 = sc.vm_grows()
    var gen2 = sc.vm_generation()
    var steps2 = sc.vm_steps()

    # (1) No heap-block event on a warm scratch, at either length.
    assert_equal(g1 - g0, 0, String("a warm short search allocated ", g1 - g0, " times"))
    assert_equal(g2 - g1, 0, String("a warm long search allocated ", g2 - g1, " times"))
    # (2) Every list kept its capacity: the same heap blocks served both lengths.
    var cap_after = sc.vm_capacity()
    for k in range(len(cap_warm)):
        assert_equal(cap_after[k], cap_warm[k], String("list ", k, " changed capacity"))
    # (3) The `seen` set is cleared by a generation bump per byte position, not
    # by writing the array: the generation moves by at least one per position.
    assert_true(gen1 - gen0 >= small, String("seen set not reset by generation: moved ", gen1 - gen0))
    assert_true(gen2 - gen1 >= large, String("seen set not reset by generation: moved ", gen2 - gen1))
    # (4) The arm is not vacuous: it really steps that many threads per byte.
    assert_true(steps1 - steps0 >= min_steps_per_byte * small, String("only ", steps1 - steps0, " threads stepped"))
    assert_true(steps2 - steps1 >= min_steps_per_byte * large, String("only ", steps2 - steps1, " threads stepped"))


def test_epsilon_closure_alternation_does_not_allocate_per_step() raises:
    # ⛔ THE RED FOR FIX A, arm 1: 15 SPLITs per seed.  Before Fix A every
    # SPLIT/SAVE allocated a fresh `List[Int]`, `_add_thread` allocated its
    # closure stacks on every call, and the `seen` set was memset per byte.
    # Each of those shows up here: a list that grows or is rebuilt bumps the
    # grow witness, and a memset in place of the generation bump leaves the
    # generation still.  The witness reads the capacities of the VM's own
    # lists; a temporary list made and freed inside the closure is not one of
    # them and is not seen.
    _assert_epsilon_closure_is_allocation_free("(?:a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p)zz", 16)


def test_epsilon_closure_char_class_does_not_allocate_per_step() raises:
    # Arm 2: `[a-p]zz` has almost no SPLITs, so it guards the per-seed and
    # per-thread allocations (init slots, stack_pc, stack_slots, the SAVE copy)
    # rather than the SPLIT cost.  A fix that only cheapened SPLIT passes arm 1
    # and fails here.
    _assert_epsilon_closure_is_allocation_free("[a-p]zz", 1)


def test_a_scratch_rebuilt_per_call_is_not_free() raises:
    # The witness's own falsifier: constructing a fresh scratch per call is the
    # allocation pattern Fix A removed, and it must read as growth every time.
    var prog = RegexProgram.compile("[a-p]zz", "")
    var s = _letters(256, 16)
    for _ in range(3):
        var sc = RegexScratch()
        assert_false(prog.is_match_with(Span(s), sc))
        assert_true(sc.vm_grows() > 0, "a fresh scratch must register growth")
    var warm = RegexScratch()
    assert_false(prog.is_match_with(Span(s), warm))
    var before = warm.vm_grows()
    for _ in range(3):
        assert_false(prog.is_match_with(Span(s), warm))
    assert_equal(warm.vm_grows(), before, "a reused scratch must not grow")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
