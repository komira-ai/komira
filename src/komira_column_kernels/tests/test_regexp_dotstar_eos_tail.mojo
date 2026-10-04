# =============================================================================
# REGEXP FIX C — THE FUSED `.*` + `\z` TAIL.  Arming witness + semantics floor.
# =============================================================================
#
# ⛔ WHY THIS FILE EXISTS.  `komira_column_kernels/regexp_nfa.mojo` gained a THIRD
# perf rewrite on the Pike VM (after FIX B's doomed-seed elision and FIX A's
# allocator pass), and it is the first one that changes WHAT THE PROGRAM IS
# rather than how it is executed:
#
#   FIX C — `_install_dotstar_eos_tail` fuses the instruction triple a trailing
#           `.*` / `.*?` compiles to, plus its `\z` exit chain, into a single
#           `OP_TAIL_MATCH`.  At run time `_closure` TELEPORTS that thread to
#           `len(subject)` instead of stepping the remaining bytes one at a
#           time, because `$` has already pinned the match end there.
#
# WHY IT IS WORTH A DEDICATED FILE.  MEASURED on 20,000 REAL ClickBench
# `referer` values (non-empty, mean 81.89 B), `find` with captures, arms as
# SEPARATE BINARIES, 3 interleaved repetitions of min-of-5:
#
#     before FIX C   5,312 / 5,324 / 5,293 ns per row
#     after  FIX C   2,420 / 2,452 / 2,461 ns per row      -> 2.17x
#
# with `matched` (18,500) and the sum of all group-1 lengths (241,370)
# BYTE-IDENTICAL between the two arms.  Marginal cost per subject byte falls
# 48.85 -> 0.74 ns (66x); what is left is the `\n` scan.
#
# ⛔⛔ AND THE FAILURE MODE IS A WRONG ANSWER, NOT A CRASH.  Every gate in the
# recogniser is load-bearing and each one, removed, produces a PLAUSIBLE wrong
# span rather than an error:
#
#   * accept `ASSERT_EOL` as well as `ASSERT_EOS`  -> `(?m)a.*$` on `"xa\nyz"`
#     answers (1,5) where RE2 answers (1,2).  A multiline `$` does NOT pin the
#     end of the subject.  THIS IS THE SINGLE MOST IMPORTANT GATE.
#   * skip the `\n` scan                          -> `a.*$` on `"xa\nyz"`
#     answers (1,5) where RE2 answers NO MATCH.
#   * write `pos` rather than `n` into the chain's SAVEs -> every match end is
#     the position the tail was ENTERED at, not the end of the subject.
#   * fuse when the exit chain does not reach MATCH -> a `.*$` in the middle of
#     a pattern (`a.*$|b`, `(a.*)*$`) would terminate the whole match early.
#
# ORACLE.  Every expected value below was produced by the REAL RE2 that DuckDB
# v1.5.5 ships (`third_party/re2/re2/*.cc` + `util/*.cc`), compiled and run
# over the same subjects — not recalled, and not a
# nearby version.  A 4,200-case differential fuzz over the same two engines
# (patterns drawn from a `.*$`-family grammar x random subjects containing
# `\n`, `/` and `.`) reported ZERO divergences.
#
# ⚠ THE PERF LEG IS A FLATNESS TEST, NOT AN ABSOLUTE ONE.  It compares a long
# tail against a short one IN THE SAME PROCESS with the arms interleaved, so no
# cross-machine constant is baked in and no allocator state from one arm can be
# read as the other's cost.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.time import perf_counter_ns

from komira_column_kernels.regexp_nfa import (
    RegexProgram,
    OP_TAIL_MATCH,
    OP_SPLIT,
    OP_ANY,
    OP_JMP,
    ANCHOR_BOS,
)
from komira_column_kernels.regexp_functions import (
    _str_bytes,
    regexp_replace_scalar,
    regexp_extract_scalar,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _q28() -> String:
    return "^https?://(?:www\\.)?([^/]+)/.*$"


def _fused(pattern: String, flags: String = "") raises -> Int:
    """How many `OP_TAIL_MATCH` instructions `pattern` compiles to."""
    var prog = RegexProgram.compile(pattern, flags)
    var k = 0
    for i in range(len(prog.prog)):
        if prog.prog[i].op == OP_TAIL_MATCH:
            k += 1
    return k


def _spans(subject: String, pattern: String, flags: String = "") raises -> List[Int]:
    """`[start, end, g1s, g1e, g2s, g2e, ...]`, or an empty list on no match."""
    var prog = RegexProgram.compile(pattern, flags)
    var m = prog.find(_str_bytes(subject))
    var out = List[Int]()
    if not m.matched:
        return out^
    for g in range(0, prog.n_groups + 1):
        var sp = m.group_span(g)
        out.append(sp[0])
        out.append(sp[1])
    return out^


def _show(v: List[Int]) -> String:
    if len(v) == 0:
        return "NO MATCH"
    var s = String("")
    for i in range(0, len(v), 2):
        s += String("g", i // 2, "=(", v[i], ",", v[i + 1], ") ")
    return s


def _assert_spans(subject: String, pattern: String, expect: List[Int], flags: String = "") raises:
    var got = _spans(subject, pattern, flags)
    assert_equal(
        len(got), len(expect),
        String("pattern ", pattern, " on ", repr(subject), ": ", _show(got), " but RE2 says ", _show(expect)),
    )
    for i in range(len(expect)):
        assert_equal(
            got[i], expect[i],
            String("pattern ", pattern, " on ", repr(subject), ": ", _show(got), " but RE2 says ", _show(expect)),
        )


def _sp(a: Int, b: Int) -> List[Int]:
    var v = List[Int]()
    v.append(a)
    v.append(b)
    return v^


def _sp2(a: Int, b: Int, c: Int, d: Int) -> List[Int]:
    var v = _sp(a, b)
    v.append(c)
    v.append(d)
    return v^


def _sp3(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int) -> List[Int]:
    var v = _sp2(a, b, c, d)
    v.append(e)
    v.append(f)
    return v^


def _none() -> List[Int]:
    return List[Int]()


# ---------------------------------------------------------------------------
# 1. THE ARMING WITNESS.  Without FIX C every count below is 0, so this whole
#    section is the leg that goes RED when the rewrite is reverted.
#    ⚠ An arming witness is NOT a correctness proof -- sections 2-5 are.
# ---------------------------------------------------------------------------


def test_fix_c_arms_on_the_q28_pattern() raises:
    assert_equal(
        _fused(_q28()), 1,
        "ClickBench Q28's pattern must fuse its trailing `.*$` -- it is the whole reason FIX C exists",
    )


def test_fix_c_arms_on_the_dotstar_eos_family() raises:
    assert_equal(_fused("^.*$"), 1)
    assert_equal(_fused(".*$"), 1)
    assert_equal(_fused("(.*)$"), 1)
    assert_equal(_fused("a.*$"), 1)
    # `\z` is the same assertion spelled explicitly.
    assert_equal(_fused("a.*\\z"), 1)
    # A LAZY tail collapses to the same answer: `$` pins the end either way.
    assert_equal(_fused("x.*?$"), 1)
    assert_equal(_fused("(x.*?)$"), 1)
    # `(?s)` makes `.` match `\n` too -- fused, and with NO newline scan at all.
    assert_equal(_fused("(?s)a.*$"), 1)
    # SAVEs on BOTH sides of the assert (group closes before `$`).
    assert_equal(_fused("(a)(.*)$"), 1)


def test_fix_c_refuses_a_multiline_dollar() raises:
    # ⛔⛔ THE GATE THAT MATTERS MOST.  Under `m`, `$` compiles to ASSERT_EOL,
    # which holds at every line end -- it does NOT pin the end of the subject,
    # so the tail may not be skipped.
    assert_equal(_fused("a.*$", "m"), 0)
    assert_equal(_fused("(?m)a.*$"), 0)
    assert_equal(_fused("(?m)^.*$"), 0)


def test_fix_c_refuses_everything_that_is_not_a_terminal_dotstar_eos() raises:
    # No end anchor at all: the tail is a real search.
    assert_equal(_fused("a.*"), 0)
    assert_equal(_fused("^https?://(?:www\\.)?([^/]+)/.*"), 0)
    # Something CONSUMES after the star.
    assert_equal(_fused("a.*b"), 0)
    assert_equal(_fused("a.*b$"), 0)
    # The star is not a `.` -- a class loop keeps its per-byte semantics.
    assert_equal(_fused("a[0-9]*$"), 0)
    assert_equal(_fused("a[^/]*$"), 0)
    # `+` is not `*` (it has a mandatory first byte; different fragment shape).
    assert_equal(_fused("a.+$"), 0)
    # The exit chain must reach MATCH.  Here it reaches the alternation's JMP.
    assert_equal(_fused("a.*$|b"), 0)
    # ... and here the enclosing star's back-edge.
    assert_equal(_fused("(a.*)*$"), 0)
    # A word boundary between the star and the end anchor is not a SAVE.
    assert_equal(_fused("a.*\\b$"), 0)


def test_fix_c_leaves_the_start_anchor_classification_alone() raises:
    # FIX B's answer must survive FIX C: `OP_TAIL_MATCH` carries the SAME two
    # targets the SPLIT did, so `classify_start_anchor` reads it unchanged.
    assert_equal(Int(RegexProgram.compile(_q28(), "").start_anchor), Int(ANCHOR_BOS))
    assert_equal(Int(RegexProgram.compile("^.*$", "").start_anchor), Int(ANCHOR_BOS))


def test_fix_c_is_idempotent_under_copy() raises:
    # ⛔ `RegexProgram.copy` re-enters `__init__`, which re-runs the
    # recogniser over an ALREADY-fused program.  If that were not a no-op the
    # copy would silently differ from its original.
    var prog = RegexProgram.compile(_q28(), "")
    var dup = prog.copy()
    var a = 0
    var b = 0
    for i in range(len(prog.prog)):
        if prog.prog[i].op == OP_TAIL_MATCH:
            a += 1
    for i in range(len(dup.prog)):
        if dup.prog[i].op == OP_TAIL_MATCH:
            b += 1
    assert_equal(a, 1)
    assert_equal(b, 1, "copy() lost or double-applied the fused tail")
    assert_equal(len(prog.prog), len(dup.prog))
    # And the copy answers identically.
    assert_equal(
        regexp_extract_scalar("http://www.example.com/a/b", dup, 1), "example.com"
    )


def test_fix_c_rewrites_exactly_one_field() raises:
    # The proof that no jump target can have been invalidated: the fused site's
    # `a`/`b` and every neighbouring instruction are byte-for-byte what the
    # compiler emitted, and only `op` changed.
    var prog = RegexProgram.compile(_q28(), "")
    var at = -1
    for i in range(len(prog.prog)):
        if prog.prog[i].op == OP_TAIL_MATCH:
            at = i
    assert_true(at >= 0, "no fused tail to inspect")
    assert_equal(prog.prog[at].a, at + 1, "the fused site must still carry the greedy SPLIT's body target")
    assert_equal(prog.prog[at].b, at + 3, "the fused site must still carry the greedy SPLIT's exit target")
    assert_equal(Int(prog.prog[at + 1].op), Int(OP_ANY), "the `.` body instruction was moved or deleted")
    assert_equal(Int(prog.prog[at + 2].op), Int(OP_JMP), "the loop back-edge was moved or deleted")
    assert_equal(prog.prog[at + 2].a, at, "the back-edge no longer points at the fused site")


# ---------------------------------------------------------------------------
# 2. SEMANTICS.  Expected values from the REAL RE2 of DuckDB v1.5.5.
#    These pass BEFORE and AFTER -- they are the floor the rewrite must not
#    move, and they are what goes red under a mutated recogniser.
# ---------------------------------------------------------------------------


def test_q28_spans_match_re2() raises:
    var q = _q28()
    _assert_spans("http://www.example.com/a/b/c", q, _sp2(0, 28, 11, 22))
    _assert_spans("https://foo.bar/", q, _sp2(0, 16, 8, 15))
    # ⭐ THE BACKTRACK CASE.  After `www.` is stripped `[^/]+` has nothing left
    # to consume, so the optional group must give the `www.` BACK to group 1.
    # A strip-then-scan lowering gets this silently wrong; the Pike VM does not.
    _assert_spans("http://www./a", q, _sp2(0, 13, 7, 11))
    # A `\n` anywhere in the tail kills the match outright, because `.` cannot
    # cross it and `$` will not stop before the end of the subject.
    _assert_spans("http://x.com/a\nb", q, _none())
    _assert_spans("http://x.com/ab\n", q, _none())


def test_dotstar_eos_spans_match_re2() raises:
    _assert_spans("abc", "(.*)$", _sp2(0, 3, 0, 3))
    # Leftmost match is the one AFTER the newline -- nothing starting at or
    # before it can reach the end of the subject.
    _assert_spans("ab\ncd", "(.*)$", _sp2(3, 5, 3, 5))
    _assert_spans("ab\n", "(.*)$", _sp2(3, 3, 3, 3))
    _assert_spans("xayz", "a.*$", _sp(1, 4))
    _assert_spans("xa\nyz", "a.*$", _none())
    _assert_spans("", "^.*$", _sp(0, 0))
    _assert_spans("\n", "^.*$", _none())
    _assert_spans("", ".*$", _sp(0, 0))
    # `(?s)` -- the newline is consumable, so the whole rest matches.
    _assert_spans("xa\nyz", "(?s)a.*$", _sp(1, 5))
    # Lazy tails still end at the end of the subject.
    _assert_spans("xabc", "x.*?$", _sp(0, 4))
    _assert_spans("xabc", "(x.*?)$", _sp2(0, 4, 0, 4))


def test_priority_is_unchanged_by_the_fused_tail() raises:
    # ⛔ THE FUSION MAKES A THREAD MATCH EARLIER IN THE STEP SEQUENCE THAN IT
    # USED TO.  Leftmost-first says the preferred alternative still wins, and
    # these are the cases that would expose it if it did not.
    _assert_spans("abc", "(a|ab).*$", _sp2(0, 3, 0, 1))
    _assert_spans("abc", "(a|ab)(.*)$", _sp3(0, 3, 0, 1, 1, 3))
    _assert_spans("abc", "(.*)(.*)$", _sp3(0, 3, 0, 3, 3, 3))
    _assert_spans("aaab", "^(a*).*$", _sp2(0, 4, 0, 3))
    _assert_spans("ab", "(a.*)*$", _sp2(0, 2, 0, 2))


def test_unfused_shapes_still_match_re2() raises:
    # The refusals from section 1, answered.  A recogniser that wrongly fused
    # any of these would answer one of these three lines differently.
    _assert_spans("xa\nyz", "(?m)a.*$", _sp(1, 2))
    _assert_spans("xayz", "a.*\\z", _sp(1, 4))
    _assert_spans("xa\nyz", "a.*$|b", _none())


def test_regexp_replace_over_the_fused_tail_matches_re2() raises:
    assert_equal(
        regexp_replace_scalar(
            "http://www.example.com/a/b/c", RegexProgram.compile(_q28(), ""), "\\1", False
        ),
        "example.com",
    )
    # RE2 returns the input UNCHANGED when the match fails, and so do we.
    assert_equal(
        regexp_replace_scalar(
            "http://x.com/a\nb", RegexProgram.compile(_q28(), ""), "\\1", False
        ),
        "http://x.com/a\nb",
    )
    assert_equal(
        regexp_replace_scalar("ab\ncd", RegexProgram.compile("(.*)$", ""), "[\\1]", False),
        "ab\n[cd]",
    )


# ---------------------------------------------------------------------------
# 3. THE METAMORPHIC RELATION.  The one a row count cannot fake, and the one
#    the fusion is most able to break: the tail bytes must not be able to
#    influence the answer, and the match must always end at the end.
# ---------------------------------------------------------------------------


def _tail_of(length: Int, seed: Int) -> String:
    var s = String("")
    for k in range(length):
        s += chr(97 + (k * 7 + seed) % 26)
    return s


def test_tail_length_cannot_move_group_one_or_the_match_end() raises:
    var q = _q28()
    var prog = RegexProgram.compile(q, "")
    var heads = List[String]()
    heads.append("http://www.example.com/")
    heads.append("https://a.b.c.d/")
    heads.append("http://www./")          # the backtrack shape, with a tail
    heads.append("http://xn--p1ai.xn--80/")
    for hi in range(len(heads)):
        var head = heads[hi]
        var base = _spans(head, q)
        assert_true(len(base) > 0, String("head ", head, " must match on its own"))
        var lengths = List[Int]()
        lengths.append(1); lengths.append(2); lengths.append(7); lengths.append(63)
        lengths.append(64); lengths.append(65); lengths.append(255); lengths.append(1031)
        for li in range(len(lengths)):
            var subj = head + _tail_of(lengths[li], hi)
            var m = prog.find(_str_bytes(subj))
            assert_true(m.matched, String("tail of ", lengths[li], " B killed the match on ", head))
            # (a) the match ALWAYS ends at the end of the subject -- that is
            #     what `$` means, and a `pos`-for-`n` mutation breaks it here.
            assert_equal(
                m.end, subj.byte_length(),
                String("`$` did not pin the end: head=", head, " tail=", lengths[li]),
            )
            assert_equal(m.start, base[0])
            # (b) group 1 is IDENTICAL to what the bare head produced: the tail
            #     bytes are invisible to it.
            var g1 = m.group_span(1)
            assert_equal(g1[0], base[2], String("tail moved group 1 start: head=", head, " tail=", lengths[li]))
            assert_equal(g1[1], base[3], String("tail moved group 1 end: head=", head, " tail=", lengths[li]))


def test_a_newline_anywhere_in_the_tail_kills_the_match_at_every_offset() raises:
    # The `\n` scan is the ONLY per-byte work the fused tail still does, so it
    # is the only place an off-by-one can hide.  Walk the newline through every
    # position of the tail, including both ends.
    var q = _q28()
    var prog = RegexProgram.compile(q, "")
    var head = String("http://www.example.com/")
    var tail_len = 17
    for at in range(tail_len):
        var tail = String("")
        for k in range(tail_len):
            tail += "\n" if k == at else "z"
        var subj = head + tail
        assert_false(
            prog.find(_str_bytes(subj)).matched,
            String("a `\\n` at tail offset ", at, " must kill the match"),
        )
    # ... and the same subject with no newline at all still matches.
    var clean = head + _tail_of(tail_len, 0)
    assert_true(prog.find(_str_bytes(clean)).matched)
    # Under `(?s)` the identical subject matches, newline and all.
    var sprog = RegexProgram.compile("(?s)" + q, "")
    assert_true(sprog.find(_str_bytes(head + "zz\nzz")).matched)


def test_the_group_key_is_a_real_subslice_of_its_own_input() raises:
    # ⭐ THE SELF-CONSISTENCY ORACLE, at kernel scope.  For every subject the
    # key `regexp_replace(s, q28, '\1')` must be EXACTLY the bytes of `s` at
    # group 1's reported span, AND re-applying the pattern to a URL rebuilt
    # from that key must reproduce the key.  A packing / offset error returns a
    # PLAUSIBLE WRONG STRING at a correct row count; this relation does not.
    var q = _q28()
    var prog = RegexProgram.compile(q, "")
    var subs = List[String]()
    subs.append("http://www.example.com/a/b/c?x=1")
    subs.append("https://sub.domain.co.uk/")
    subs.append("http://www./a")
    subs.append("http://127.0.0.1:8080/path")
    subs.append("https://www.a/b")
    subs.append("http://q/")
    for i in range(len(subs)):
        var s = subs[i]
        var m = prog.find(_str_bytes(s))
        assert_true(m.matched, String("expected a match on ", s))
        var g1 = m.group_span(1)
        var key = regexp_replace_scalar(s, prog, "\\1", False)
        var bytes = _str_bytes(s)
        var slice_ = List[UInt8]()
        for k in range(g1[0], g1[1]):
            slice_.append(bytes[k])
        assert_equal(
            key, String(StringSlice(unsafe_from_utf8=Span[UInt8](slice_))),
            String("the replace output is not the bytes at group 1's span for ", s),
        )
        # Idempotence: `http://<key>/` must extract to `<key>` again.  This is
        # what catches a key that is plausible but off by a field.
        assert_equal(
            regexp_replace_scalar("http://" + key + "/", prog, "\\1", False),
            key,
            String("the extracted key does not reproduce itself for ", s),
        )


# ---------------------------------------------------------------------------
# 4. PERF.  A FLATNESS test: the fused tail must make the cost stop depending
#    on the tail length.  Arms interleaved ABAB in one process, min of 3.
# ---------------------------------------------------------------------------


def _bench_ns(prog: RegexProgram, subjects: List[List[UInt8]], reps: Int) -> Int:
    var best = Int(1) << 62
    for _ in range(reps):
        var t0 = perf_counter_ns()
        var sink = 0
        for i in range(len(subjects)):
            var m = prog.find(subjects[i])
            if m.matched:
                sink += m.end
        var t1 = perf_counter_ns()
        if sink == -1:
            print("")          # keep the loop from being optimised away
        if t1 - t0 < best:
            best = t1 - t0
    return best


def _subjects(n: Int, tail: Int) -> List[List[UInt8]]:
    # ⚠ Build the tail ONCE.  A per-byte `String +=` inside the row loop is
    # quadratic and dominated the whole test at 1 KiB tails.
    var filler = List[UInt8](capacity=tail)
    for k in range(tail):
        filler.append(UInt8(97 + k % 26))
    var out = List[List[UInt8]]()
    for i in range(n):
        var head = String("http://www.h", i % 97, ".example.com/")
        var hb = head.as_bytes()
        var b = List[UInt8](capacity=len(hb) + tail)
        for j in range(len(hb)):
            b.append(hb[j])
        for j in range(tail):
            b.append(filler[j])
        out.append(b^)
    return out^


def test_cost_is_flat_in_tail_length() raises:
    # ⛔ WHY A RATIO AND NOT AN ABSOLUTE ns FIGURE.  An absolute bar bakes in
    # one machine's clock.  This compares a 1,024-byte tail against a 4-byte
    # one in the SAME process, interleaved, so the only thing it can measure is
    # whether the tail is still being walked.
    #
    # MEASURED, 20,000 real referers: without the early-out the marginal cost
    # is 48.85 ns per subject byte, with it 0.74 (66x).  Over a 1,020-byte
    # tail difference that is ~49,800 ns/row vs ~750 -- so the unfused ratio
    # here is ~15x and the fused ratio ~1.2x.  The bar is 3.0: far above
    # anything the `\n` scan can produce and far below the unfused cost.
    var prog = RegexProgram.compile(_q28(), "")
    var short_ = _subjects(400, 4)
    var long_ = _subjects(400, 1024)
    # ABAB: allocator state left by one arm must not be read as the other's.
    var s1 = _bench_ns(prog, short_, 3)
    var l1 = _bench_ns(prog, long_, 3)
    var s2 = _bench_ns(prog, short_, 3)
    var l2 = _bench_ns(prog, long_, 3)
    var s = s1 if s1 < s2 else s2
    var l = l1 if l1 < l2 else l2
    assert_true(s > 0 and l > 0, "the timing loop produced no time")
    var ratio = Float64(l) / Float64(s)
    assert_true(
        ratio < 3.0,
        String(
            "the trailing `.*$` is still being walked byte by byte: 1024B-tail=",
            l, "ns 4B-tail=", s, "ns ratio=", ratio,
            " (bar 3.0; measured ~15x unfused, ~1.2x fused)",
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
