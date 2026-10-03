# =============================================================================
# REGEXP BITSTATE — RE2's bounded backtracker, the capture-call engine.
# =============================================================================
#
# WHAT IT IS.  A port of RE2's `Prog::SearchBitState` (`re2/bitstate.cc`,
# google/re2 @ main, BSD-3-Clause; the ALGORITHM is ported, no C++ was
# copied) over OUR compiled program (`RegexProgram.prog`, the same `Inst`
# stream the Pike VM runs).  It is a depth-first backtracker with two things
# that make it safe:
#
#   * a VISITED bitmap, one bit per (pc, text position).  A state is executed
#     at most once per search, so the search is O(prog_len * text_len) --
#     linear in the text, no catastrophic backtracking;
#   * an explicit JOB STACK instead of recursion.  A SPLIT pushes its
#     lower-priority arm and continues with the higher one; a SAVE pushes an
#     UNDO job (restore the slot's old value) before writing.  The first MATCH
#     reached is the answer.
#
# WHY IT EXISTS.  RE2 dispatches exactly this call shape -- a capture call on a
# small text -- to BitState and never runs its DFA for it (`re2.cc:836-839`:
# `if (can_bit_state && text.size() <= bit_state_text_max_size && ncap > 1)
# { skipped_test = true; break; }`).  On a URL-rewriting program (ClickBench
# Q28's) over short subjects BitState is ~6x faster per call than the Pike
# VM (~0.5 us vs ~3.3 us).  The Pike VM steps every live
# thread per byte and copies a capture vector per thread; BitState carries ONE
# capture vector and undoes writes on backtrack.
#
# ⛔ THE INVARIANT: IT IS THE PIKE VM'S ANSWER, NOT A NEAR ONE.  Leftmost-first
# priority is the DFS order: SPLIT `a` before `b` (the Pike closure pops `a`
# first for the same reason), earlier start positions before later ones, and
# the first MATCH wins.  The visited bitmap is the Pike VM's per-position
# `seen` stamp, marked at the same instructions (EVERY pc executed, not just
# consuming ones) -- a (pc, p) state reached twice is reached first by the
# higher-priority path in both engines, so pruning the second arrival discards
# the same thread.  OP_TAIL_MATCH is executed exactly as `_closure` executes it.
# Enforced by `komira_column_kernels/tests/test_regexp_bitstate_differential.mojo`:
# every (pattern, subject, start) of a committed corpus plus a seeded random
# generator, both engines forced, every slot compared.
#
# ⭐ ONE DEPARTURE FROM RE2, AND WHY IT IS SAFE.  RE2 memsets the whole
# `list_count * (text.size()+1)`-bit bitmap on every search.  Here the bitmap
# is POSITION-MAJOR (bit = (p - start) * prog_len + pc) and a search clears
# only the rows up to the furthest position it touched.  An anchored pattern
# that fails on byte 3 of a 6 KB subject clears ~3 rows, not 6 KB of rows.
# The scratch's contract is "all-zero between searches"; `bitstate_search`
# restores it before returning, on every path.
#
# SIZE POLICY (RE2's): BitState runs iff `prog_len * (text_len + 1) <=
# BITSTATE_MAX_VISITED_BITS` (256 Ki bits = a 32 KiB bitmap).  RE2 states the
# same budget over `list_count` (`prog.cc:650-651`, `bit_state_text_max_size =
# 256*1024 / list_count - 1`); we have no flattened lists, so we charge per
# instruction, which is the stricter of the two.  Outside the budget the
# caller runs the Pike VM.  The dispatch lives in
# `RegexProgram.find_from_with_engine` (`regexp_nfa.mojo`).
# =============================================================================

from komira_column_kernels.regexp_nfa import (
    RegexProgram,
    OP_CHAR,
    OP_CLASS,
    OP_ANY,
    OP_MATCH,
    OP_JMP,
    OP_SPLIT,
    OP_SAVE,
    OP_ASSERT,
    OP_TAIL_MATCH,
    ANCHOR_BOS,
    _seed_can_survive,
    _tail_has_newline,
)


comptime BITSTATE_MAX_VISITED_BITS: Int = 256 * 1024
"""RE2's BitState budget: the visited bitmap may hold at most this many bits."""


@always_inline
def bitstate_fits(prog_len: Int, text_len: Int) -> Bool:
    """RE2's policy: may a search over `text_len` bytes run on BitState?"""
    return prog_len * (text_len + 1) <= BITSTATE_MAX_VISITED_BITS


struct BitStateScratch(Movable):
    """Reusable BitState execution state.  Lives inside `RegexScratch`, so a
    columnar kernel holds one per column and every row reuses its heap blocks.

    ⛔ CONTRACT: `visited` is ALL-ZERO between searches (`bitstate_search`
    restores it before returning), and `jobs`/`caps` carry nothing across
    searches (they are re-armed on entry).  So a scratch may be reused across
    rows, subjects and programs.
    """

    var visited: List[UInt64]   # position-major (pc, p) bitmap; see header
    var jobs: List[Int]         # (id, p) pairs; id < 0 = undo SAVE of slot -id-1
    var caps: List[Int]         # the ONE live capture vector
    var searches: Int           # witness: BitState searches run on this scratch

    def __init__(out self):
        self.visited = List[UInt64]()
        self.jobs = List[Int]()
        self.caps = List[Int]()
        self.searches = 0


def bitstate_search(
    prog: RegexProgram,
    subject: Span[UInt8, _],
    min_start: Int,
    mut bs: BitStateScratch,
    mut match_slots: List[Int],
) -> Bool:
    """Leftmost-first search at or after `min_start`, with captures.

    On return `match_slots` holds `prog.n_slots` values: the match's capture
    slots if it matched, else all -1 -- the same shape the Pike VM leaves in
    `RegexScratch.match_slots`.  The whole subject is the assertion context
    (`^`, `\\b`, ... see the bytes before `min_start`), exactly as in the Pike
    VM.  Runs at ANY size; the budget is the caller's policy
    (`bitstate_fits`), not a correctness limit.
    """
    var n = len(subject)
    var L = len(prog.prog)
    var nslots = prog.n_slots
    bs.searches += 1
    match_slots.clear()
    for _ in range(nslots):
        match_slots.append(-1)
    if min_start > n:
        return False
    var need = (L * (n - min_start + 1) + 63) >> 6
    if len(bs.visited) < need:
        bs.visited.resize(need, UInt64(0))
    if len(bs.caps) != nslots:
        bs.caps = List[Int](length=nslots, fill=-1)
    else:
        for j in range(nslots):
            bs.caps[j] = -1
    # `hi` = the furthest text position any visited bit was written for; the
    # clear below covers rows [min_start, hi].
    var hi = min_start
    var anchor = prog.start_anchor
    var matched = False
    var p0 = min_start
    while p0 <= n:
        if anchor == ANCHOR_BOS and p0 > 0:
            break                     # only position 0 can ever seed
        if _seed_can_survive(anchor, subject, p0):
            if p0 > hi:
                hi = p0
            # ⭐ `caps` needs no reset between start positions: a FAILED try
            # pops every job it pushed, and every SAVE pushed its own undo, so
            # the vector is back to all -1.  A successful try ends the search.
            if _bitstate_try(prog, subject, n, min_start, nslots, p0, bs, match_slots, hi):
                matched = True
                break
        p0 += 1
    # Restore the all-zero contract over every row this search could have
    # written: rows 0 .. (hi - min_start), i.e. bits [0, (hi-min_start+1)*L).
    var used = ((hi - min_start + 1) * L + 63) >> 6
    if used > len(bs.visited):
        used = len(bs.visited)
    for w in range(used):
        bs.visited[w] = 0
    return matched


def _bitstate_try(
    prog: RegexProgram,
    subject: Span[UInt8, _],
    n: Int,
    base: Int,
    nslots: Int,
    p0: Int,
    mut bs: BitStateScratch,
    mut match_slots: List[Int],
    mut hi: Int,
) -> Bool:
    """One start position: DFS from (pc 0, `p0`).  True iff a MATCH was
    reached, with its slots in `match_slots`.  `base` is the text position
    of bitmap row 0."""
    var L = len(prog.prog)
    bs.jobs.clear()
    bs.jobs.append(0)
    bs.jobs.append(p0)
    while len(bs.jobs) > 0:
        var p = bs.jobs.pop()
        var id = bs.jobs.pop()
        if id < 0:
            # Undo a SAVE: slot (-id - 1) gets back the value it held before.
            bs.caps[-id - 1] = p
            continue
        while True:
            # Visit (id, p) at most once -- the Pike VM's `seen` stamp.
            var key = (p - base) * L + id
            var w = key >> 6
            var bit = UInt64(1) << UInt64(key & 63)
            var word = bs.visited[w]
            if (word & bit) != 0:
                break
            bs.visited[w] = word | bit
            var ins = prog.prog[id]
            var op = ins.op
            if op == OP_CHAR:
                if p < n and Int(subject[p]) == ins.a:
                    id += 1
                    p += 1
                    if p > hi:
                        hi = p
                    continue
                break
            elif op == OP_CLASS:
                if p < n and prog._class_matches(ins.a, Int(subject[p])):
                    id += 1
                    p += 1
                    if p > hi:
                        hi = p
                    continue
                break
            elif op == OP_ANY:
                if p < n and (ins.a == 1 or Int(subject[p]) != 10):
                    id += 1
                    p += 1
                    if p > hi:
                        hi = p
                    continue
                break
            elif op == OP_SPLIT:
                # `a` is the higher-priority arm: run it now, `b` later.
                bs.jobs.append(ins.b)
                bs.jobs.append(p)
                id = ins.a
                continue
            elif op == OP_JMP:
                id = ins.a
                continue
            elif op == OP_SAVE:
                if ins.a < nslots:
                    bs.jobs.append(-ins.a - 1)
                    bs.jobs.append(bs.caps[ins.a])
                    bs.caps[ins.a] = p
                id += 1
                continue
            elif op == OP_ASSERT:
                if prog._assert_holds(ins.a, subject, p, n):
                    id += 1
                    continue
                break
            elif op == OP_MATCH:
                for j in range(nslots):
                    match_slots[j] = bs.caps[j]
                return True
            elif op == OP_TAIL_MATCH:
                # ⭐ The fused `.*` + `\z` tail, executed exactly as the Pike
                # VM's `_closure` executes it: the thread survives to `n` iff the
                # rest of the subject holds no `\n` (or the `.` is dotall), and
                # every SAVE on the proven `[SAVE]* ASSERT_EOS [SAVE]* MATCH`
                # exit chain writes `n`.  Otherwise it dies here.
                var dotall_tail = prog.prog[id + 1].a == 1
                if dotall_tail or not _tail_has_newline(subject, p, n):
                    for j in range(nslots):
                        match_slots[j] = bs.caps[j]
                    var tpc = id + 3
                    while True:
                        var t = prog.prog[tpc]
                        if t.op == OP_SAVE:
                            if t.a < nslots:
                                match_slots[t.a] = n
                            tpc += 1
                        elif t.op == OP_ASSERT:
                            tpc += 1
                        else:
                            break        # OP_MATCH
                    return True
                break
            else:
                break
    return False
