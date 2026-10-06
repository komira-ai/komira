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
from std.time import perf_counter_ns

from komira_column_kernels.regexp_nfa import (
    RegexProgram,
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
# 7. PERF — the RED/GREEN for Fix B.  RATIO-based, so it is independent of
#    machine speed; the real effect is ~1000x on this input and the bar is 8x.
# ---------------------------------------------------------------------------


def _time_ns_matching(pattern: String, subject: List[UInt8], reps: Int) raises -> Int:
    var prog = RegexProgram.compile(pattern, "")
    # Warm.
    _ = prog.is_match(subject)
    var t0 = perf_counter_ns()
    for _ in range(reps):
        var m = prog.is_match(subject)
        if m:
            raise Error("regexp anchor perf pin: pattern must match NOTHING")
    return perf_counter_ns() - t0


def test_perf_anchored_no_match_is_far_cheaper_than_unanchored() raises:
    # ⛔ THE RED.  Before the doomed-seed elision these two are within ~1.4x of
    # each other (MEASURED on ClickBench Q28: 6,593 s vs 9,400 s of CPU) because
    # the anchored program is seeded at every byte position and only discovers
    # `^` cannot hold one epsilon-step later, AFTER allocating the slot vector.
    # After the elision the anchored arm does O(1) work per subject.
    var n = 32768
    var subj = List[UInt8](capacity=n)
    for i in range(n):
        subj.append(UInt8(ord("a") + (i % 23)))
    var anchored = _time_ns_matching("^ZQXJ://[^/]+/", subj, 3)
    var unanchored = _time_ns_matching("ZQXJ://[^/]+/", subj, 3)
    # 8x is a floor with two orders of magnitude of headroom; it is not a
    # measurement, it is a refusal to regress to the old behaviour.
    assert_true(
        unanchored > 8 * anchored,
        String(
            "anchored seed elision is not in effect: anchored=",
            anchored,
            "ns unanchored=",
            unanchored,
            "ns ratio=",
            Float64(unanchored) / Float64(max(anchored, 1)),
        ),
    )


def _calibrate_ns(subject: List[UInt8], reps: Int) -> Int:
    """A machine-speed RULER: allocation-free, non-vectorisable byte work over
    the same buffer the regexp arms walk.

    ⭐ WHY A RULER AND NOT A WALL CLOCK.  The perf pin below has to survive
    running on any farm worker, so it asserts a DIMENSIONLESS ratio.  This loop
    carries a serial dependency (`acc` feeds itself), so it cannot be
    vectorised away and it tracks core clock and nothing else.  MEASURED, it
    reproduced to 0.1% across two different binaries: 2,995,416 ns and
    2,992,317 ns for the same 200 reps.
    """
    var best = -1
    var sink = 0
    for _ in range(4):
        var t0 = perf_counter_ns()
        for _ in range(reps):
            var acc = 1
            for i in range(len(subject)):
                acc = (acc * 31 + Int(subject[i])) & 0xFFFFFFF
            sink += acc
        var dt = perf_counter_ns() - t0
        if best < 0 or dt < best:
            best = dt
    if sink == -12345:      # never true; keeps the loop from being elided
        return -1
    return best


def _bench_is_match_ns(pattern: String, subject: List[UInt8], reps: Int) raises -> Int:
    var prog = RegexProgram.compile(pattern, "")
    _ = prog.is_match(subject)          # warm
    var best = -1
    for _ in range(4):
        var t0 = perf_counter_ns()
        for _ in range(reps):
            _ = prog.is_match(subject)
        var dt = perf_counter_ns() - t0
        if best < 0 or dt < best:
            best = dt
    return best


def test_perf_the_epsilon_closure_is_not_allocating_per_step() raises:
    # ⛔ THE RED FOR FIX A, in units of the ruler above.
    #
    # Before Fix A every epsilon SPLIT/SAVE allocated a fresh `List[Int]`
    # capture vector, `_add_thread` allocated its two closure stacks on EVERY
    # call, `slots_for` allocated one more list per thread per byte position,
    # and `reset` memset the whole `seen` array once per byte.  MEASURED on
    # ClickBench Q28 that is an 81.73% allocator profile at IPC 1.87 -- pure
    # instruction count, nothing stalling.
    #
    # MEASURED HERE, same subject, same reps, both arms normalised by the ruler:
    #
    #     arm                              pre-Fix-A   post-Fix-A   bar
    #     16-way alternation (many SPLITs)    40.17        8.60      20.0
    #     equivalent char class (no SPLITs)    7.52        1.72       4.0
    #
    # Each bar sits ~2.0x below the old value and ~2.3x above the new one.  Both
    # arms are kept because the alternation arm alone would let a fix that only
    # cheapened SPLIT pass; the char-class arm has almost no SPLITs and still
    # moved 4.4x, which is the seed and per-thread allocations going away.
    var n = 8192
    var subj = List[UInt8](capacity=n)
    for i in range(n):
        subj.append(UInt8(ord("a") + (i % 16)))

    var ruler = _calibrate_ns(subj, 200)
    assert_true(ruler > 0, "calibration loop produced no time")

    var alt = _bench_is_match_ns("(?:a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p)zz", subj, 3)
    var alt_r = Float64(alt) / Float64(ruler)
    assert_true(
        alt_r < 20.0,
        String(
            "epsilon SPLIT steps still allocate: alt=", alt,
            "ns ruler=", ruler, "ns ratio=", alt_r,
            " (bar 20.0; measured pre-Fix-A 40.17, post-Fix-A 8.60)",
        ),
    )

    var cls = _bench_is_match_ns("[a-p]zz", subj, 3)
    var cls_r = Float64(cls) / Float64(ruler)
    assert_true(
        cls_r < 4.0,
        String(
            "the per-thread / per-seed allocations are still there: cls=", cls,
            "ns ruler=", ruler, "ns ratio=", cls_r,
            " (bar 4.0; measured pre-Fix-A 7.52, post-Fix-A 1.72)",
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
