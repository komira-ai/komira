# =============================================================================
# REGEXP BITSTATE == PIKE VM — the differential gate for the capture engine.
# =============================================================================
#
# ⛔ WHY THIS FILE EXISTS.  `RegexProgram.find_from_with` runs RE2's BitState
# backtracker (`komira_column_kernels/regexp_bitstate.mojo`) for every capture call
# within RE2's size budget, and the Pike VM otherwise.  The two engines must
# give the SAME answer -- matched, start, end and EVERY capture slot -- or a
# `regexp_replace` / `regexp_extract` value silently changes with the length
# of the row.  Nothing else would notice: both engines return a plausible
# match at a correct row count.
#
# THE ORACLE is the other engine.  Every case pins both engines explicitly
# (`find_from_with_engine(..., REGEX_ENGINE_PIKE / _BITSTATE)`) over the same
# program and subject, at EVERY start offset 0..len+1 (the `regexp_replace` /
# `find_all` loops call `find_from` at interior offsets, where `^` / `\b`
# must still see the bytes before the start).  Inputs:
#
#   1. the committed corpus -- the regexp patterns the engine's own tests
#      and benchmarks use, plus the constructs the two
#      engines are most likely to disagree on: alternation priority, lazy vs
#      greedy, empty-width loops, empty matches, every assertion, the fused
#      `.*$` tail, flags, and multi-byte UTF-8;
#   2. a SEEDED random generator of (pattern, subject) pairs -- deterministic,
#      so a failure reproduces from the printed seed.
#
# ⭐ AND A PIN THAT DOES NOT COME FROM EITHER ENGINE.  A differential cannot see
# both engines being wrong the SAME way, so `test_leftmost_first_pins` states
# Perl/RE2's answer for the classic priority cases by hand.
#
# MUTATION-VERIFIED, each run with `mojo run` against this file:
#   * swapping SPLIT priority in `_bitstate_try` (run `b` before `a`) turns
#     4 of the 5 tests RED (first hit: `((a)|(b))+` on "ab");
#   * clearing one bitmap row too few after a search (`hi - min_start`
#     instead of `hi - min_start + 1`) turns 3 of the 5 RED, including the
#     scratch-reuse test.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_column_kernels.regexp_nfa import (
    RegexProgram,
    RegexScratch,
    RegexMatch,
    REGEX_ENGINE_PIKE,
    REGEX_ENGINE_BITSTATE,
    REGEX_ENGINE_AUTO,
)
from komira_column_kernels.regexp_bitstate import bitstate_fits


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _show(subj: List[UInt8]) -> String:
    var s = String("[")
    for i in range(len(subj)):
        if i > 0:
            s += ","
        s += String(Int(subj[i]))
    return s + "]"


def _show_match(m: RegexMatch) -> String:
    if not m.matched:
        return String("NOMATCH")
    var s = String("(") + String(m.start) + "," + String(m.end) + ") slots="
    for i in range(len(m.slots)):
        s += String(m.slots[i]) + " "
    return s


def _same(a: RegexMatch, b: RegexMatch) -> Bool:
    if a.matched != b.matched:
        return False
    if not a.matched:
        return True
    if a.start != b.start or a.end != b.end:
        return False
    if len(a.slots) != len(b.slots):
        return False
    for i in range(len(a.slots)):
        if a.slots[i] != b.slots[i]:
            return False
    return True


struct _Tally(Movable):
    var calls: Int      # (subject, start) pairs compared
    var matched: Int    # ...of which matched
    var progs: Int      # programs exercised

    def __init__(out self):
        self.calls = 0
        self.matched = 0
        self.progs = 0


def _diff_all_starts(
    pat: String,
    prog: RegexProgram,
    subj: List[UInt8],
    mut sc_pike: RegexScratch,
    mut sc_bits: RegexScratch,
    mut tally: _Tally,
) raises:
    """Both engines, every start offset 0..len+1, every slot."""
    var sp = Span(subj)
    for start in range(len(subj) + 2):
        var mp = prog.find_from_with_engine(sp, start, sc_pike, REGEX_ENGINE_PIKE)
        var mb = prog.find_from_with_engine(sp, start, sc_bits, REGEX_ENGINE_BITSTATE)
        tally.calls += 1
        if mp.matched:
            tally.matched += 1
        if not _same(mp, mb):
            raise Error(
                String("BITSTATE != PIKE  pattern=") + pat
                + " subject=" + _show(subj)
                + " start=" + String(start)
                + "\n  pike     " + _show_match(mp)
                + "\n  bitstate " + _show_match(mb)
            )


# ---------------------------------------------------------------------------
# 1. The committed corpus.
# ---------------------------------------------------------------------------


def _corpus() -> List[String]:
    var v = List[String]()
    # The pattern corpus of komira_compiler's one-pass qualifier test, minus
    # the seven that do not compile.
    v.append("((a)(b))(c)")
    v.append("((a)|(b))+")
    v.append("()")
    v.append("(?:a*)*")
    v.append("(?P<name>a)")
    v.append("(?P<y>\\d+)-(?P<m>\\d+)-(?P<d>\\d+)")
    v.append("(?P<year>\\d+)-(?P<month>\\d+)")
    v.append("(?P<year>\\d+)-(?P<month>\\d+)-(?P<day>\\d+)")
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
    v.append("^ZQXJ://(?:www\\.)?([^/]+)/.*$")
    v.append("ZQXJ://(?:www\\.)?([^/]+)/.*$")
    # Alternation priority and lazy/greedy -- leftmost-FIRST, not longest.
    v.append("(a|ab)(c|bcd)(d*)")
    v.append("(ab|a)(bc|c)")
    v.append("(a|b|ab|ba)*")
    v.append("(a*?)(a*?)(a*)")
    v.append("(a+?)b")
    v.append("(a??)(a)")
    v.append("(a{1,3}?)(a*)")
    v.append("(a{2,}?)(a*)")
    v.append("x*?y*?")
    v.append("(.*?)(b)(.*)")
    v.append("(.*)(b)(.*?)")
    # Empty-width loops and empty matches -- the `seen`/visited prune decides.
    v.append("(a*)*")
    v.append("(a*)+")
    v.append("(a|)*")
    v.append("(|a)*")
    v.append("(|a)+")
    v.append("((a)|b)*?c")
    v.append("(a?)*?b")
    v.append("(?:(a)|(b)|())*")
    v.append("")
    v.append("a*")
    v.append("(a*)*b")
    # Every assertion, in and out of multiline.
    v.append("\\bab\\b")
    v.append("\\Ba\\B")
    v.append("(?m)^(\\w+)$")
    v.append("(?m)^")
    v.append("(?m)$")
    v.append("$")
    v.append("^$")
    v.append("\\A\\z")
    v.append("a\\z")
    v.append("(?m)(^a|b$)")
    v.append("(?:^|,)(\\w*)")
    # The fused `.*$` tail -- dotall, lazy, with and without \n.
    v.append(".*$")
    v.append(".*?$")
    v.append("(.*)$")
    v.append("(?s)(.*)$")
    v.append("a(.*)$")
    v.append("^(a)(.*)$")
    v.append("(?m)a(.*)$")
    v.append("(b|.*$)")
    # Flags.
    v.append("(?i)AbC")
    v.append("(?i)(a+)(B)")
    v.append("(?s)a.b")
    v.append("a.b")
    v.append("(?i:a)b")
    v.append("(?x) a b # comment")
    # Multi-byte UTF-8 (byte-based engine: a 2-byte literal is two CHARs).
    v.append("é+")
    v.append("(é|e)(x?)")
    v.append("[^a]+")
    v.append("(.)(.)")
    v.append("€(\\d+)")
    return v^


def _fixed_subjects() -> List[List[UInt8]]:
    var s = List[List[UInt8]]()
    s.append(_bytes(""))
    s.append(_bytes("a"))
    s.append(_bytes("ab"))
    s.append(_bytes("abc"))
    s.append(_bytes("abcd"))
    s.append(_bytes("aaa"))
    s.append(_bytes("aab"))
    s.append(_bytes("bab"))
    s.append(_bytes("abab"))
    s.append(_bytes("xyz"))
    s.append(_bytes("aaab"))
    s.append(_bytes("AbC abc"))
    s.append(_bytes("ab ab,ab"))
    s.append(_bytes("a\nb\n"))
    s.append(_bytes("\na\n"))
    s.append(_bytes("line1\nline2"))
    s.append(_bytes("2026-09-23"))
    s.append(_bytes("12-34"))
    s.append(_bytes("key:42"))
    s.append(_bytes("foo bar_baz"))
    s.append(_bytes("a,b,,c"))
    s.append(_bytes("http://www.example.com/path?q=1"))
    s.append(_bytes("https://example.com/"))
    s.append(_bytes("https://example.com"))
    s.append(_bytes("http://www./x"))
    s.append(_bytes("http://a.b/c\nd"))
    s.append(_bytes("ZQXJ://www.x/y"))
    s.append(_bytes("xx https://y.z/w"))
    s.append(_bytes("café"))
    s.append(_bytes("éé e"))
    s.append(_bytes("€123 €"))
    s.append(_bytes("aé\nb"))
    var raw = List[UInt8]()
    raw.append(0xFF)
    raw.append(0x61)
    raw.append(0xC3)
    raw.append(0x0A)
    raw.append(0x00)
    raw.append(0x62)
    s.append(raw^)
    return s^


def test_corpus_bitstate_equals_pike_at_every_start() raises:
    var pats = _corpus()
    var subs = _fixed_subjects()
    var sc_p = RegexScratch()
    var sc_b = RegexScratch()
    var tally = _Tally()
    for pi in range(len(pats)):
        var prog = RegexProgram.compile(pats[pi], "")
        tally.progs += 1
        for si in range(len(subs)):
            _diff_all_starts(pats[pi], prog, subs[si], sc_p, sc_b, tally)
    print("corpus: programs", tally.progs, "comparisons", tally.calls, "matched", tally.matched)
    # Vacuity floors: a corpus that silently shrank, or an engine that never
    # matches, must not read as green.
    assert_true(tally.progs >= 90, "corpus shrank")
    assert_true(tally.matched * 10 >= tally.calls, "too few matching cases to mean anything")


# ---------------------------------------------------------------------------
# 2. Seeded random (pattern, subject) pairs.
# ---------------------------------------------------------------------------


struct _Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> UInt64:
        # xorshift64*
        self.s ^= self.s >> 12
        self.s ^= self.s << 25
        self.s ^= self.s >> 27
        return self.s * 2685821657736338717

    def below(mut self, n: Int) -> Int:
        return Int((self.next() >> 33) % UInt64(n))


def _gen_atom(mut rng: _Rng) -> String:
    var k = rng.below(20)
    if k == 0:
        return String("a")
    if k == 1:
        return String("b")
    if k == 2:
        return String("c")
    if k == 3:
        return String(".")
    if k == 4:
        return String("[ab]")
    if k == 5:
        return String("[^a]")
    if k == 6:
        return String("\\d")
    if k == 7:
        return String("\\w")
    if k == 8:
        return String("\\s")
    if k == 9:
        return String("\\b")
    if k == 10:
        return String("\\B")
    if k == 11:
        return String("^")
    if k == 12:
        return String("$")
    if k == 13:
        return String("é")
    if k == 14:
        return String("\\n")
    if k == 15:
        return String("a")
    if k == 16:
        return String("\\A")
    if k == 17:
        return String("\\z")
    if k == 18:
        return String("[a-c\\n]")
    return String("b")


def _gen_quant(mut rng: _Rng) -> String:
    var k = rng.below(14)
    if k == 0:
        return String("*")
    if k == 1:
        return String("+")
    if k == 2:
        return String("?")
    if k == 3:
        return String("*?")
    if k == 4:
        return String("+?")
    if k == 5:
        return String("??")
    if k == 6:
        return String("{0,2}")
    if k == 7:
        return String("{1,3}?")
    if k == 8:
        return String("{2}")
    if k == 9:
        return String("{1,}")
    return String("")


def _gen_regex(mut rng: _Rng, depth: Int) -> String:
    var k = rng.below(10) if depth < 3 else 0
    if k <= 3:
        return _gen_atom(rng) + _gen_quant(rng)
    if k <= 5:
        var s = String("")
        var parts = 1 + rng.below(3)
        for _ in range(parts):
            s += _gen_regex(rng, depth + 1)
        return s
    if k == 6:
        var s = _gen_regex(rng, depth + 1)
        var alts = 1 + rng.below(2)
        for _ in range(alts):
            s += "|" + _gen_regex(rng, depth + 1)
        return s
    if k == 7:
        return String("(") + _gen_regex(rng, depth + 1) + ")" + _gen_quant(rng)
    if k == 8:
        return String("(?:") + _gen_regex(rng, depth + 1) + ")" + _gen_quant(rng)
    return String("(") + _gen_regex(rng, depth + 1) + "|" + _gen_regex(rng, depth + 1) + ")" + _gen_quant(rng)


def _gen_flags(mut rng: _Rng) -> String:
    var k = rng.below(8)
    if k == 0:
        return String("i")
    if k == 1:
        return String("m")
    if k == 2:
        return String("s")
    if k == 3:
        return String("ms")
    return String("")


def _gen_subject(mut rng: _Rng) -> List[UInt8]:
    var alphabet = List[UInt8]()
    alphabet.append(UInt8(ord("a")))
    alphabet.append(UInt8(ord("a")))
    alphabet.append(UInt8(ord("b")))
    alphabet.append(UInt8(ord("b")))
    alphabet.append(UInt8(ord("c")))
    alphabet.append(UInt8(ord("A")))
    alphabet.append(UInt8(ord("1")))
    alphabet.append(UInt8(ord(" ")))
    alphabet.append(UInt8(ord("_")))
    alphabet.append(UInt8(ord("/")))
    alphabet.append(UInt8(10))
    alphabet.append(UInt8(0xC3))
    alphabet.append(UInt8(0xA9))
    alphabet.append(UInt8(0xFF))
    var n = rng.below(18)
    var out = List[UInt8]()
    for _ in range(n):
        out.append(alphabet[rng.below(len(alphabet))])
    return out^


def test_randomized_bitstate_equals_pike() raises:
    comptime SEED: UInt64 = 0x9E3779B97F4A7C15
    comptime N_PATTERNS: Int = 1500
    comptime N_SUBJECTS: Int = 12
    var rng = _Rng(SEED)
    var sc_p = RegexScratch()
    var sc_b = RegexScratch()
    var tally = _Tally()
    var refused = 0
    for _ in range(N_PATTERNS):
        var pat = _gen_regex(rng, 0)
        var flags = _gen_flags(rng)
        var prog: RegexProgram
        try:
            prog = RegexProgram.compile(pat, flags)
        except:
            refused += 1
            continue
        tally.progs += 1
        for _ in range(N_SUBJECTS):
            var subj = _gen_subject(rng)
            _diff_all_starts(pat + " /" + flags, prog, subj, sc_p, sc_b, tally)
    print(
        "random: seed", SEED, "programs", tally.progs, "refused", refused,
        "comparisons", tally.calls, "matched", tally.matched,
    )
    assert_true(tally.progs >= N_PATTERNS // 2, "generator produced too few compilable patterns")
    assert_true(tally.calls >= 100_000, "too few comparisons to mean anything")
    assert_true(tally.matched * 10 >= tally.calls, "too few matching cases to mean anything")


# ---------------------------------------------------------------------------
# 3. Pins that come from neither engine (Perl / RE2 leftmost-first).
# ---------------------------------------------------------------------------


def _pin(pat: String, subj: String, want: List[Int]) raises:
    """`want` = the expected slot vector; an empty `want` = no match."""
    var prog = RegexProgram.compile(pat, "")
    var b = _bytes(subj)
    for engine in [REGEX_ENGINE_PIKE, REGEX_ENGINE_BITSTATE, REGEX_ENGINE_AUTO]:
        var sc = RegexScratch()
        var m = prog.find_from_with_engine(Span(b), 0, sc, engine)
        var label = pat + " on '" + subj + "' engine " + String(Int(engine))
        if len(want) == 0:
            assert_false(m.matched, label)
            continue
        assert_true(m.matched, label)
        assert_equal(len(m.slots), len(want), label)
        for i in range(len(want)):
            assert_equal(m.slots[i], want[i], label + " slot " + String(i))


def test_leftmost_first_pins() raises:
    # (a|ab) takes `a` FIRST; (c|bcd) must then take `bcd`.
    _pin("(a|ab)(c|bcd)(d*)", "abcd", [0, 4, 0, 1, 1, 4, 4, 4])
    # Lazy takes one; greedy takes the rest.
    _pin("(a+?)(a*)", "aaa", [0, 3, 0, 1, 1, 3])
    # An empty-width loop matches empty at 0, its group empty at 0.
    _pin("(a*)+", "b", [0, 0, 0, 0])
    # (ab|a) prefers `ab`, leaving `c` for (bc|c).
    _pin("(ab|a)(bc|c)", "abc", [0, 3, 0, 2, 2, 3])
    # Leftmost START wins over a longer later match.
    _pin("a|bcd", "xbcda", [1, 4])
    # `^` does not re-match mid-string; `(?m)^` would.
    _pin("^b", "ab", List[Int]())
    # A URL-host pattern: group 1 is the host without `www.`.
    _pin("^https?://(?:www\\.)?([^/]+)/.*$", "http://www.example.com/p", [0, 24, 11, 22])
    # A `\n` in the fused `.*$` tail kills the match.
    _pin("^https?://(?:www\\.)?([^/]+)/.*$", "http://a.b/c\nd", List[Int]())


# ---------------------------------------------------------------------------
# 4. The production dispatch.
# ---------------------------------------------------------------------------


def test_auto_takes_bitstate_within_budget_and_pike_beyond() raises:
    var prog = RegexProgram.compile("^https?://(?:www\\.)?([^/]+)/.*$", "")
    var L = len(prog.prog)
    var small = _bytes("https://www.example.org/a/b/c")
    assert_true(bitstate_fits(L, len(small)))
    var sc = RegexScratch()
    var m = prog.find_from_with(Span(small), 0, sc)
    assert_true(m.matched)
    assert_equal(sc.bits.searches, 1, "a small capture call must run BitState")
    # Over RE2's budget: the Pike VM, and the SAME answer.
    var big = _bytes("https://www.example.org/")
    while bitstate_fits(L, len(big)):
        for _ in range(512):
            big.append(UInt8(ord("x")))
    var mb = prog.find_from_with(Span(big), 0, sc)
    assert_equal(sc.bits.searches, 1, "an over-budget subject must NOT run BitState")
    var sc2 = RegexScratch()
    var forced = prog.find_from_with_engine(Span(big), 0, sc2, REGEX_ENGINE_BITSTATE)
    assert_true(_same(mb, forced), "BitState forced over budget must still agree")
    # The boolean call stays on the Pike VM.
    _ = prog.is_match_with(Span(small), sc)
    assert_equal(sc.bits.searches, 1, "is_match must not run BitState")


def test_scratch_reuse_leaves_no_stale_visited_bits() raises:
    """The scratch's bitmap must be all-zero between searches: a long search
    followed by a short one, a different program, and an interior start must
    each equal a fresh scratch."""
    var progs = List[RegexProgram]()
    progs.append(RegexProgram.compile("(a|ab)(c|bcd)(d*)", ""))
    progs.append(RegexProgram.compile("^https?://(?:www\\.)?([^/]+)/.*$", ""))
    progs.append(RegexProgram.compile("(\\w+)$", "m"))
    var subs = List[List[UInt8]]()
    var long = _bytes("https://")
    for _ in range(3000):
        long.append(UInt8(ord("a")))
    long.append(UInt8(ord("/")))
    subs.append(long^)
    subs.append(_bytes("abcd"))
    subs.append(_bytes("http://www.x.io/"))
    subs.append(_bytes("ab\ncd"))
    var sc = RegexScratch()
    for round in range(3):
        for pi in range(len(progs)):
            for si in range(len(subs)):
                var sp = Span(subs[si])
                for start in range(0, len(subs[si]) + 1, 7):
                    var reused = progs[pi].find_from_with_engine(sp, start, sc, REGEX_ENGINE_BITSTATE)
                    var fresh_sc = RegexScratch()
                    var fresh = progs[pi].find_from_with_engine(sp, start, fresh_sc, REGEX_ENGINE_BITSTATE)
                    assert_true(
                        _same(reused, fresh),
                        String("reused scratch diverged: round ") + String(round)
                        + " prog " + String(pi) + " subj " + String(si)
                        + " start " + String(start),
                    )
    for w in range(len(sc.bits.visited)):
        assert_equal(sc.bits.visited[w], UInt64(0), "visited not restored to all-zero")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
