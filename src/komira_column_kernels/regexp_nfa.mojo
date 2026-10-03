# =============================================================================
# REGEXP — pure-Mojo RE2-style Thompson NFA / Pike VM matcher.
# =============================================================================
#
# Approach: parse the pattern -> a recursive AST -> compile each node into a
# self-contained instruction "fragment" with 0-relative internal targets ->
# stitch the fragments -> simulate with the Pike VM (Thompson construction +
# a "set of active threads" simulation carrying capture-slot arrays —
# exactly RE2's NFA executor / the `regex` crate's `pikevm.rs`).  Linear time
# O(len(subject) * len(program)) — no backtracking, no catastrophic-
# backtracking DoS.  Leftmost-first (Perl) match semantics for captures,
# which is what RE2 / DuckDB / DataFusion use.
#
# Dialect: POSIX-ERE + the RE2/`regex`-crate Perl-ish subset — literals,
# `.`, char classes `[...]`/`[^...]` (ranges, `\d\w\s` + negations, POSIX
# `[[:alpha:]]`, escaped metachars), anchors `^ $ \A \z \b \B`, quantifiers
# `* + ? {n} {n,} {n,m}` greedy + non-greedy, alternation `|`, grouping
# `(...)` capturing / `(?:...)` non-capturing / `(?i:...)` scoped flags,
# inline flags `(?i)(?m)(?s)(?x)`, flags param `i g m s x`.  Rejects
# pathological/invalid patterns at compile time (`a**`, unbalanced parens,
# trailing `\`, `a{2,1}`, backref-in-pattern `\1`, lookaround).
#
# Encapsulation: NO UnsafePointer in any public signature.  The whole engine
# is `List[Inst]` + `List[Thread]` + byte iteration over a `List[UInt8]`
# view of the subject.  Public API: `RegexProgram.compile(pattern, flags)`
# -> a `RegexProgram` (Movable, Copyable POD-instruction list); the match
# methods take a `List[UInt8]` and return typed values (Bool / a
# `RegexMatch` of (start,end) spans).
#
# PERF: programs are compiled per batch; compiling once per plan and
# stashing the program in the Expr node is a hygiene change, not a
# performance one — see the PERF note in `regexp_functions.mojo`.
#
# ⭐ TWO ENGINES, ONE ANSWER.  A capture call (`find_with` / `find_from_with`)
# runs RE2's BitState backtracker (`regexp_bitstate.mojo`) when
# `prog_len * (text_len + 1) <= 256 Ki bits` -- RE2's own dispatch for this
# call shape -- and this Pike VM otherwise.  `is_match_with` always runs the
# Pike VM.  The two are held to the same answer, slot for slot, by
# `komira_column_kernels/tests/test_regexp_bitstate_differential.mojo`.
# =============================================================================

from std.memory import ArcPointer
from komira_column_kernels.regexp_bitstate import BitStateScratch, bitstate_fits, bitstate_search


# ---------------------------------------------------------------------------
# Engine selection for the capture calls (`find_from_with_engine`).
# ---------------------------------------------------------------------------
comptime REGEX_ENGINE_AUTO: UInt8 = 0      # production: BitState within budget, else Pike
comptime REGEX_ENGINE_PIKE: UInt8 = 1      # force the Pike VM (the differential reference)
comptime REGEX_ENGINE_BITSTATE: UInt8 = 2  # force BitState at any size (the differential arm)


# ---------------------------------------------------------------------------
# Char-class bitmap: a 256-bit set over byte values, stored as 8 x UInt32.
# ---------------------------------------------------------------------------


struct ByteClass(Movable, Copyable, ImplicitlyCopyable):
    """A 256-bit set of byte values (a regex character class)."""
    var w0: UInt32
    var w1: UInt32
    var w2: UInt32
    var w3: UInt32
    var w4: UInt32
    var w5: UInt32
    var w6: UInt32
    var w7: UInt32

    @always_inline
    def __init__(out self):
        self.w0 = 0
        self.w1 = 0
        self.w2 = 0
        self.w3 = 0
        self.w4 = 0
        self.w5 = 0
        self.w6 = 0
        self.w7 = 0

    @always_inline
    def _word(self, i: Int) -> UInt32:
        if i == 0: return self.w0
        if i == 1: return self.w1
        if i == 2: return self.w2
        if i == 3: return self.w3
        if i == 4: return self.w4
        if i == 5: return self.w5
        if i == 6: return self.w6
        return self.w7

    @always_inline
    def _set_word(mut self, i: Int, v: UInt32):
        if i == 0: self.w0 = v
        elif i == 1: self.w1 = v
        elif i == 2: self.w2 = v
        elif i == 3: self.w3 = v
        elif i == 4: self.w4 = v
        elif i == 5: self.w5 = v
        elif i == 6: self.w6 = v
        else: self.w7 = v

    @always_inline
    def add(mut self, b: Int):
        var w = b >> 5
        var bit = b & 31
        self._set_word(w, self._word(w) | (UInt32(1) << UInt32(bit)))

    @always_inline
    def add_range(mut self, lo: Int, hi: Int):
        var i = lo
        while i <= hi:
            self.add(i)
            i += 1

    @always_inline
    def contains(self, b: Int) -> Bool:
        var w = b >> 5
        var bit = b & 31
        return (self._word(w) & (UInt32(1) << UInt32(bit))) != 0

    @always_inline
    def union_with(mut self, other: ByteClass):
        self.w0 |= other.w0
        self.w1 |= other.w1
        self.w2 |= other.w2
        self.w3 |= other.w3
        self.w4 |= other.w4
        self.w5 |= other.w5
        self.w6 |= other.w6
        self.w7 |= other.w7

    @always_inline
    def negate(mut self):
        self.w0 = ~self.w0
        self.w1 = ~self.w1
        self.w2 = ~self.w2
        self.w3 = ~self.w3
        self.w4 = ~self.w4
        self.w5 = ~self.w5
        self.w6 = ~self.w6
        self.w7 = ~self.w7

    @always_inline
    def add_case_folded(mut self):
        """Fold ASCII letters: if 'a' is in, add 'A', and vice versa."""
        var b = ord("A")
        while b <= ord("Z"):
            if self.contains(b):
                self.add(b + 32)
            b += 1
        b = ord("a")
        while b <= ord("z"):
            if self.contains(b):
                self.add(b - 32)
            b += 1


def _digit_class() -> ByteClass:
    var c = ByteClass()
    c.add_range(ord("0"), ord("9"))
    return c

def _word_class() -> ByteClass:
    var c = ByteClass()
    c.add_range(ord("0"), ord("9"))
    c.add_range(ord("A"), ord("Z"))
    c.add_range(ord("a"), ord("z"))
    c.add(ord("_"))
    return c

def _space_class() -> ByteClass:
    var c = ByteClass()
    c.add(ord(" "))
    c.add(ord("\t"))
    c.add(ord("\n"))
    c.add(ord("\r"))
    c.add(0x0C)  # \f
    c.add(0x0B)  # \v
    return c

@always_inline
def _is_word_byte(b: Int) -> Bool:
    return (b >= ord("0") and b <= ord("9")) or (b >= ord("A") and b <= ord("Z")) or (b >= ord("a") and b <= ord("z")) or b == ord("_")


# ---------------------------------------------------------------------------
# Regex flags.
# ---------------------------------------------------------------------------


struct RegexFlags(Movable, Copyable, ImplicitlyCopyable):
    var case_insensitive: Bool   # i
    var multiline: Bool          # m
    var dotall: Bool             # s
    var extended: Bool           # x  (whitespace ignored in pattern)
    var global_: Bool            # g  (only meaningful for replace/find_all)

    @always_inline
    def __init__(out self):
        self.case_insensitive = False
        self.multiline = False
        self.dotall = False
        self.extended = False
        self.global_ = False

    def copy(self) -> Self:
        var f = RegexFlags()
        f.case_insensitive = self.case_insensitive
        f.multiline = self.multiline
        f.dotall = self.dotall
        f.extended = self.extended
        f.global_ = self.global_
        return f


def parse_flags_string(s: String) raises -> RegexFlags:
    var f = RegexFlags()
    var bs = s.as_bytes()
    for ci in range(len(bs)):
        var ch = Int(bs[ci])
        if ch == ord("i"):
            f.case_insensitive = True
        elif ch == ord("m"):
            f.multiline = True
        elif ch == ord("s"):
            f.dotall = True
        elif ch == ord("x"):
            f.extended = True
        elif ch == ord("g"):
            f.global_ = True
        else:
            raise Error("regexp: unknown flag character '" + chr(ch) + "'")
    return f


# ---------------------------------------------------------------------------
# Instruction set for the Pike VM.
# ---------------------------------------------------------------------------

comptime OP_CHAR: UInt8 = 0       # match the specific byte (a == byte value)
comptime OP_CLASS: UInt8 = 1      # match a byte in classes[a]
comptime OP_ANY: UInt8 = 2        # match any byte (a==1 -> also \n; a==0 -> not \n)
comptime OP_MATCH: UInt8 = 3      # accept
comptime OP_JMP: UInt8 = 4        # goto a
comptime OP_SPLIT: UInt8 = 5      # try a first (higher priority), then b
comptime OP_SAVE: UInt8 = 6       # save current position into capture slot a
comptime OP_ASSERT: UInt8 = 7     # zero-width assertion of kind a
comptime OP_TAIL_MATCH: UInt8 = 8  # FUSED `.*` + `\z` tail -- see `_install_dotstar_eos_tail`

comptime ASSERT_BOL: UInt8 = 0    # ^  (start of line, multiline)
comptime ASSERT_EOL: UInt8 = 1    # $  (end of line, multiline)
comptime ASSERT_BOS: UInt8 = 2    # \A (absolute start of string; also ^ when not multiline)
comptime ASSERT_EOS: UInt8 = 3    # \z (absolute end of string; also $ when not multiline)
comptime ASSERT_WORD_B: UInt8 = 4   # \b
comptime ASSERT_NOT_WORD_B: UInt8 = 5  # \B

# ---------------------------------------------------------------------------
# START-ANCHOR CLASSIFICATION (perf, not semantics).
# ---------------------------------------------------------------------------
#
# ⭐ WHAT THIS BUYS.  The Pike VM is an UNANCHORED search: `_run` seeds a fresh
# start thread at every byte position until a match is found.  For a program
# that begins with `^` / `\A` every seed after the line start is DOOMED — the
# `ASSERT` one epsilon-step later can never hold — but it is doomed only AFTER
# `init_slots`, the closure stacks and a SAVE-copy of the slot vector have all
# been allocated.  On a URL-rewriting pattern such as ClickBench Q28's those
# doomed seeds were ~40% of the whole regexp cost, and a pattern matching ZERO
# rows still burned its CPU proving `^` cannot match.
#
# ⛔ THIS IS A SEED FILTER, NOT A SEMANTIC RULE.  It is only ever allowed to
# skip a seed the `ASSERT` would have killed anyway, so the classification must
# be CONSERVATIVE: any epsilon path from pc 0 that reaches a consuming
# instruction (or MATCH) without passing a start anchor makes the program
# `ANCHOR_NONE`.  `^a|b` is NOT anchored.
comptime ANCHOR_NONE: UInt8 = 0   # seed at every position
comptime ANCHOR_BOS: UInt8 = 1    # every path passes \A / non-multiline ^  -> seed at pos 0 only
comptime ANCHOR_BOL: UInt8 = 2    # every path passes ^ under `m`            -> seed at pos 0 and after \n


# ---------------------------------------------------------------------------
# THE FUSED `.*` + `\z` TAIL  (perf, not semantics).
# ---------------------------------------------------------------------------
#
# ⭐ WHAT THIS BUYS, AND WHY IT IS THE BIGGEST THING ON THE TABLE.  The Pike VM
# steps ONE BYTE AT A TIME, carrying `nslots` capture ints per live thread.  For
# a pattern whose LAST construct is `.*$` — ClickBench Q28's
# `^https?://(?:www\.)?([^/]+)/.*$` is exactly this shape — the answer is fully
# determined the moment the `.*` is entered: `$` (non-multiline) pins the match
# end at `len(subject)`, and `.` consumes everything up to it.  Every byte after
# that point is walked purely to arrive at a conclusion already known.
#
# MEASURED (`find()` with captures):
#   `^.*$`                              -> 42.0 ns per subject byte
#   `^https?://(?:www\.)?([^/]+)/.*$`   -> 48.0 / 49.5 ns per subject byte
#   the same pattern with `.*$` DELETED -> 0.0 ns/byte (FLAT: 2,418 ns at 27 B,
#                                          2,393 ns at 523 B)
# i.e. the trailing `.*$` IS the entire marginal per-byte cost; the host-matching
# head contributes nothing to it.
#
# ⭐⭐ AND RE2 DOES NOT DO THIS FOR `.` (IT DOES FOR `(?s).`).  Its peephole
# (`re2/prog.cc:253-283`, "Insert kInstAltMatch instructions") fires only when
# the loop body is a single ByteRange `[00-FF]`, and `.` without `(?s)` is
# `[^\n]` = TWO ranges, so the rewrite misses.  MEASURED against the RE2
# vendored in DuckDB v1.5.5, `RE2::Replace` on Q28's own pattern:
#     tail bytes      0      16      64     256    1024    4096
#     ns/row        265     345     588    1662    5334   20135
# — a 4.9 ns/byte SLOPE, i.e. RE2 walks the tail too.  This is not catch-up.
#
# ⛔ THIS IS A PROGRAM REWRITE, NOT A SEMANTIC RULE, AND THE PROOF IS THE SHAPE
# TEST.  `_install_dotstar_eos_tail` fires ONLY on the exact instruction triple a
# `.*` / `.*?` compiles to (`_compile_node`'s AST_STAR arm), positioned so that
# its loop-exit lands on a straight-line epsilon chain
# `[SAVE]* ASSERT_EOS [SAVE]* MATCH`.  Under that shape, and only under it:
#   * `ASSERT_EOS` holds iff `pos == n`, so the match end is `n` UNCONDITIONALLY
#     and every SAVE on the chain — before OR after the assert — writes `n`;
#   * `.` matches every byte except `\n` (or every byte under `(?s)`), so the
#     thread survives from `pos` to `n` iff `subject[pos:n]` holds no `\n`;
#   * nothing after the chain can consume, because the assert already pinned the
#     position at the end of the subject.
# A multiline `$` compiles to ASSERT_EOL, NOT ASSERT_EOS, and is refused here —
# that is the single most important gate in the recogniser.
#
# ⛔ IT REWRITES ONE FIELD AND MOVES NOTHING.  Only `prog[i].op` changes; `a`,
# `b` and every other instruction are left exactly as compiled.  So no jump
# target anywhere in the program can be invalidated, an instruction that jumps
# INTO the fused site still behaves correctly, and the rewrite is IDEMPOTENT
# (re-running it over an already-rewritten program is a no-op), which is what
# makes `RegexProgram.copy()` — which re-enters `__init__` — safe.


def _install_dotstar_eos_tail(mut prog: List[Inst]):
    """Fuse a trailing `.*` + `\\z` into one `OP_TAIL_MATCH`, in place.

    Recognises, at some pc `i`:

        i  : SPLIT  i+1, i+3   (greedy `.*`)   or   SPLIT i+3, i+1  (lazy `.*?`)
        i+1: ANY    (a = 1 under `(?s)`, else 0 = "any byte but \\n")
        i+2: JMP    i
        i+3: [SAVE]* ASSERT(ASSERT_EOS) [SAVE]* MATCH      (straight line)

    and turns `prog[i].op` into `OP_TAIL_MATCH`.  Everything else is untouched.
    At most ONE site is fused (the first that qualifies); refusing to fuse is
    always correct, so every judgement below resolves toward REFUSE.
    """
    var n = len(prog)
    var i = 0
    while i + 3 < n:
        if prog[i].op != OP_SPLIT:
            i += 1
            continue
        var body = i + 1
        var back = i + 2
        var exit_pc = i + 3
        var greedy = prog[i].a == body and prog[i].b == exit_pc
        var lazy = prog[i].a == exit_pc and prog[i].b == body
        if not (greedy or lazy):
            i += 1
            continue
        if prog[body].op != OP_ANY:
            i += 1
            continue
        if prog[back].op != OP_JMP or prog[back].a != i:
            i += 1
            continue
        # The exit chain: `[SAVE]* ASSERT_EOS [SAVE]* MATCH`, strictly linear.
        # ⛔ No JMP arm on purpose — a jump would have to be mirrored byte-for-
        # byte by `_closure`'s run-time walk, and an alternation tail is not
        # worth that risk.
        var pc = exit_pc
        var saw_eos = False
        var good = False
        while pc < n:
            var op = prog[pc].op
            if op == OP_SAVE:
                pc += 1
            elif op == OP_ASSERT:
                if saw_eos or prog[pc].a != Int(ASSERT_EOS):
                    break
                saw_eos = True
                pc += 1
            elif op == OP_MATCH:
                good = saw_eos
                break
            else:
                break
        if good:
            prog[i].op = OP_TAIL_MATCH
            return
        i += 1


@always_inline
def _tail_has_newline(subject: Span[UInt8, _], pos: Int, n: Int) -> Bool:
    """Does `subject[pos:n]` hold a `\\n`?  The ONLY thing a non-dotall `.*`
    tail can trip over."""
    var k = pos
    while k < n:
        if Int(subject[k]) == 10:
            return True
        k += 1
    return False


def classify_start_anchor(prog: List[Inst]) -> UInt8:
    """Classify where `prog` CAN begin matching.

    Walks the epsilon closure from pc 0, stopping at a start anchor (which
    pins the position) and bailing out to `ANCHOR_NONE` the moment a consuming
    instruction or MATCH is reachable without one.  Reachability with a visited
    set is exact here: there is no fixpoint to iterate, because a single
    anchor-free path to a consuming instruction is decisive on its own.

    ⚠ It reads the PROGRAM, never the pattern text — `(?m)` / `(?m:...)` toggle
    `^` between `ASSERT_BOL` and `ASSERT_BOS` mid-pattern, and only the emitted
    instruction says which one was compiled.
    """
    var n = len(prog)
    if n == 0:
        return ANCHOR_NONE
    var visited = List[Bool](length=n, fill=False)
    var stack = List[Int](capacity=8)
    stack.append(0)
    var saw_anchor = False
    var saw_bol = False
    while len(stack) > 0:
        var pc = stack.pop()
        if pc < 0 or pc >= n:
            # A malformed target cannot be PROVEN anchored.  Fail open.
            return ANCHOR_NONE
        if visited[pc]:
            continue
        visited[pc] = True
        var ins = prog[pc]
        if ins.op == OP_JMP:
            stack.append(ins.a)
        elif ins.op == OP_SPLIT or ins.op == OP_TAIL_MATCH:
            # ⭐ OP_TAIL_MATCH IS AN OP_SPLIT WITH A PROVEN SHAPE and its `a`/`b`
            # are the SAME two targets the SPLIT carried (see
            # `_install_dotstar_eos_tail`), so every analysis that only needs the
            # LANGUAGE -- this one and `one_pass_verdict` -- reads it unchanged.
            stack.append(ins.a)
            stack.append(ins.b)
        elif ins.op == OP_SAVE:
            stack.append(pc + 1)
        elif ins.op == OP_ASSERT:
            if ins.a == Int(ASSERT_BOS):
                # Barrier: past here the start position is pinned to 0.
                saw_anchor = True
            elif ins.a == Int(ASSERT_BOL):
                saw_anchor = True
                saw_bol = True
            else:
                # EOL / EOS / \b / \B constrain something OTHER than the start
                # position, so they are transparent to this analysis.
                stack.append(pc + 1)
        else:
            # OP_CHAR / OP_CLASS / OP_ANY / OP_MATCH reached with no anchor
            # crossed: this program can begin anywhere.
            return ANCHOR_NONE
    if not saw_anchor:
        return ANCHOR_NONE
    # A mix of BOL and BOS degrades to BOL: its seed set is a strict superset,
    # so it can only ever be too generous, never too tight.
    return ANCHOR_BOL if saw_bol else ANCHOR_BOS


@always_inline
def _seed_can_survive(anchor: UInt8, subject: Span[UInt8, _], sp: Int) -> Bool:
    """Can a start thread seeded at `sp` survive its own start anchor?

    ⛔ THIS MUST MIRROR `_assert_holds` EXACTLY.  It is not an approximation:
    `ASSERT_BOS` holds iff `pos == 0` and `ASSERT_BOL` iff `pos == 0` or the
    preceding byte is `\n`, and those are evaluated at the seed position itself
    during the seed's own epsilon closure.  So a seed this returns False for is
    a seed that allocates its slot vector, walks to the assert, and dies --
    skipping it is byte-for-byte equivalent, not merely close.
    """
    if anchor == ANCHOR_NONE:
        return True
    if anchor == ANCHOR_BOS:
        return sp == 0
    return sp == 0 or Int(subject[sp - 1]) == 10



struct Inst(Movable, Copyable, ImplicitlyCopyable):
    """A single Pike-VM instruction.  POD: no heap fields."""
    var op: UInt8
    var a: Int          # byte value / class index / slot / jump target / assert kind / split-target-1
    var b: Int          # split-target-2 (else unused)

    @always_inline
    def __init__(out self, op: UInt8, a: Int, b: Int):
        self.op = op
        self.a = a
        self.b = b

    def copy(self) -> Self:
        return Self(self.op, self.a, self.b)


# ---------------------------------------------------------------------------
# ONE-PASS QUALIFICATION.  STATIC ANALYSIS ONLY -- there is no runtime here.
# ---------------------------------------------------------------------------
#
# The prerequisite for a deterministic capture-carrying automaton (RE2's
# OnePass engine) is that the program qualifies. `RE2::is_one_pass_` is a
# private field with no public accessor, so whether a given pattern qualifies
# cannot be read off RE2; this function decides the same predicate over OUR
# compiled programs.
#
# ⭐ WHAT "ONE-PASS" MEANS (RE2, `re2/onepass.cc`, google/re2 @ main, BSD-3-
# Clause -- the ALGORITHM is ported, no C++ was copied):
#
#     "One-pass regular expressions have the property that at each input byte
#      during an anchored match, there may be multiple alternatives but only
#      one can proceed for any given input byte."
#
# and the three conditions `Prog::IsOnePass` checks, verbatim from its comment:
#
#     (1) for any other Inst nip, there is at most one input-free path from
#         ip to nip.
#     (2) there is at most one kInstByte instruction reachable from ip that
#         matches any particular byte c.
#     (3) there is at most one input-free path from ip to a kInstMatch
#         instruction.
#
# ⛔ (1) IS A HARD FAIL, NOT A PRUNE, AND THAT IS THE WHOLE SAFETY ARGUMENT.
# The Pike VM's own `_closure` prunes a second arrival at a pc (first-add wins
# priority).  A STATIC automaton may not: the two arrivals can carry different
# ASSERT conditions, and the table records only one action per (node, byte), so
# at runtime -- when the recorded path's assertion fails and the pruned path's
# would have held -- the automaton answers NO where the Pike VM answers YES.
# RE2 spells this `if (!AddQ(&workq, id)) goto fail;`.  So does this.
#
# ⛔ AND IT IS A CONSERVATIVE APPROXIMATION IN ONE DIRECTION ONLY.  RE2's own
# comment: "it might return false when the answer is true".  A too-strict
# qualifier costs speed; a too-loose one is a WRONG ANSWER.  Every judgement
# call below is resolved toward REJECT.
#
# ⚠ THIS ANALYSES THE PROGRAM, NEVER THE PATTERN TEXT.  `(?i)` folds a literal
# into a CLASS at parse time and `(?m)` switches `^` between ASSERT_BOL and
# ASSERT_BOS mid-pattern; only the emitted instruction says what was compiled.
# Same rule `classify_start_anchor` follows, for the same reason.

comptime ONEPASS_OK: UInt8 = 0
comptime ONEPASS_EMPTY_PROGRAM: UInt8 = 1    # nothing to analyse
comptime ONEPASS_SLOT_BUDGET: UInt8 = 2      # more capture slots than the cap mask holds
comptime ONEPASS_NODE_BUDGET: UInt8 = 3      # automaton would exceed the state budget
comptime ONEPASS_BYTE_CONFLICT: UInt8 = 4    # (2) violated: two ways to consume one byte
comptime ONEPASS_MULTIPLE_PATHS: UInt8 = 5   # (1) violated: two epsilon paths to one pc
comptime ONEPASS_MULTIPLE_MATCHES: UInt8 = 6 # (3) violated: two epsilon paths to MATCH
comptime ONEPASS_BAD_TARGET: UInt8 = 7       # malformed program (jump out of range)
comptime ONEPASS_STEP_BUDGET: UInt8 = 8      # walk did not terminate inside its budget

# ⚠ BUDGETS ARE POLICY SHAPE, NOT RE2'S CONSTANTS.  RE2 packs its whole action
# into one `uint32_t` (16 bits of index, 6 empty-width flags, `kMatchWins`, and
# 8 capture bits), which is where its `kMaxOnePassCapture = 5` comes from -- a
# BIT-PACKING limit, not a property of the predicate.  We carry the action in
# named fields, so the only real limits are the ones chosen here.
comptime ONEPASS_MAX_SLOTS: Int = 64         # cap set is a UInt64 bitmask == 31 groups
comptime ONEPASS_MAX_NODES: Int = 1024       # a 256-wide action row per node
comptime ONEPASS_MAX_STEPS: Int = 1 << 20    # termination floor, never a real verdict

# The per-byte action's condition byte: bits 0-5 are the ASSERT_* kinds (so the
# bit for kind k is `1 << k`, matching the ASSERT_* numbering above) and bit 6
# is MATCH WINS -- "a MATCH was reachable, at this node, at HIGHER priority
# than this byte transition", i.e. leftmost-first says stop rather than consume.
# Exactly RE2's `kMatchWins = 1 << kEmptyShift` layout.
comptime ONEPASS_MATCH_WINS: UInt8 = 64


struct OnePassVerdict(Movable, Copyable, ImplicitlyCopyable):
    """Does a compiled program admit a deterministic one-pass automaton?

    `ok` is the answer.  The rest is the EXPLANATION, and it is not decoration:
    a qualifier that only says "no" cannot be reviewed, and the first thing
    anyone asks of a negative is *which construct* cost it.
    """
    var ok: Bool
    var reason: UInt8
    var at_pc: Int        # instruction the analysis failed at, else -1
    var detail: Int       # conflicting byte value / duplicate target pc, else -1
    var n_nodes: Int      # automaton states discovered before the verdict

    @always_inline
    def __init__(out self, ok: Bool, reason: UInt8, at_pc: Int, detail: Int, n_nodes: Int):
        self.ok = ok
        self.reason = reason
        self.at_pc = at_pc
        self.detail = detail
        self.n_nodes = n_nodes

    def copy(self) -> Self:
        return Self(self.ok, self.reason, self.at_pc, self.detail, self.n_nodes)

    def reason_str(self) -> String:
        if self.reason == ONEPASS_OK:
            return "one-pass"
        if self.reason == ONEPASS_EMPTY_PROGRAM:
            return "empty program"
        if self.reason == ONEPASS_SLOT_BUDGET:
            return "capture-slot budget"
        if self.reason == ONEPASS_NODE_BUDGET:
            return "node budget"
        if self.reason == ONEPASS_BYTE_CONFLICT:
            return "byte conflict"
        if self.reason == ONEPASS_MULTIPLE_PATHS:
            return "multiple epsilon paths"
        if self.reason == ONEPASS_MULTIPLE_MATCHES:
            return "multiple matches"
        if self.reason == ONEPASS_BAD_TARGET:
            return "malformed jump target"
        return "step budget"

    def describe(self) -> String:
        var s = String(self.reason_str())
        if not self.ok:
            s += String(" at pc ", self.at_pc)
            if self.reason == ONEPASS_BYTE_CONFLICT:
                s += String(" on byte ", self.detail)
            elif self.reason == ONEPASS_MULTIPLE_PATHS:
                s += String(" -> pc ", self.detail)
        s += String(" (", self.n_nodes, " nodes)")
        return s^


@always_inline
def _onepass_addq(mut stamp: List[Int], gen: Int, pc: Int) -> Bool:
    """RE2's `AddQ`: True if `pc` was NOT already on this flood's work queue.

    A generation stamp, so clearing the queue between floods is `gen += 1` --
    the same idiom `_ThreadList.reset` uses, for the same reason (a memset per
    flood is what the generation stamp keeps out of the hot loop)."""
    if stamp[pc] == gen:
        return False
    stamp[pc] = gen
    return True


@always_inline
def _onepass_consumes(ins: Inst, classes: List[ByteClass], b: Int) -> Bool:
    """Does byte `b` drive consuming instruction `ins`?

    ⛔ MUST MIRROR `_run`'s consuming arms EXACTLY.  A byte this says is
    consumed but the Pike VM refuses (or vice versa) is a divergence between
    the automaton and the reference engine, which is the one failure mode that
    produces a wrong answer rather than a slow one."""
    if ins.op == OP_CHAR:
        return b == ins.a
    if ins.op == OP_CLASS:
        return classes[ins.a].contains(b)
    # OP_ANY: `a == 1` is dotall, else every byte but '\n'.
    return ins.a == 1 or b != 10


def one_pass_verdict(prog: List[Inst], classes: List[ByteClass], n_slots: Int) -> OnePassVerdict:
    """Decide whether `prog` admits a one-pass automaton.  NO automaton is
    built and nothing is executed -- this is the whole surface.

    The walk is RE2's `Prog::IsOnePass` flood, retargeted at our instruction
    set: a NODE is the start pc or the successor of a byte-consuming
    instruction, and each node's epsilon closure is explored in PRIORITY order
    (SPLIT's `a` before its `b`, the same order `_closure` adds threads) while
    accumulating the capture slots written and the ASSERTs crossed.
    """
    var n = len(prog)
    if n == 0:
        return OnePassVerdict(False, ONEPASS_EMPTY_PROGRAM, -1, -1, 0)
    if n_slots > ONEPASS_MAX_SLOTS:
        return OnePassVerdict(False, ONEPASS_SLOT_BUDGET, -1, n_slots, 0)

    # pc -> node index, and the node worklist in discovery order.
    var node_of = List[Int](length=n, fill=-1)
    var tovisit = List[Int](capacity=16)
    node_of[0] = 0
    tovisit.append(0)
    var nalloc = 1

    # Per-node scratch.  Reused across floods; `act_next[b] == -1` is RE2's
    # `kImpossible` (no transition on this byte).
    var act_next = List[Int](length=256, fill=-1)
    var act_caps = List[UInt64](length=256, fill=0)
    var act_cond = List[UInt8](length=256, fill=0)

    # This flood's work queue (condition (1)), generation-stamped.
    var seen = List[Int](length=n, fill=0)
    var gen = 0

    # The priority DFS stack: (pc, caps written so far, ASSERTs crossed).
    var st_pc = List[Int](capacity=16)
    var st_caps = List[UInt64](capacity=16)
    var st_cond = List[UInt8](capacity=16)

    var steps = 0
    var ni = 0
    while ni < len(tovisit):
        var node_pc = tovisit[ni]
        ni += 1
        for b in range(256):
            act_next[b] = -1
            act_caps[b] = 0
            act_cond[b] = 0
        gen += 1
        var matched = False

        st_pc.clear()
        st_caps.clear()
        st_cond.clear()
        st_pc.append(node_pc)
        st_caps.append(0)
        st_cond.append(0)
        # ⚠ `node_pc` is deliberately NOT stamped, mirroring RE2 (its `AddQ` is
        # called on successors only).  Termination does not depend on it: every
        # successor is stamped, so a cycle back through one fails condition (1).
        while len(st_pc) > 0:
            var pc = st_pc.pop()
            var caps = st_caps.pop()
            var cond = st_cond.pop()
            while True:
                steps += 1
                if steps > ONEPASS_MAX_STEPS:
                    return OnePassVerdict(False, ONEPASS_STEP_BUDGET, pc, -1, nalloc)
                if pc < 0 or pc >= n:
                    return OnePassVerdict(False, ONEPASS_BAD_TARGET, pc, -1, nalloc)
                var ins = prog[pc]
                # ⭐ OP_TAIL_MATCH is an OP_SPLIT whose two targets are proven to
                # be [the `.` body] and [the `\z` exit chain]; it carries the
                # SAME `a`/`b`, so reading it as a SPLIT here is not an
                # approximation -- it is the identical language walk the
                # pre-fusion program produced.  (This analysis is priority-blind:
                # it rejects on ANY conflict, in either exploration order.)
                if ins.op == OP_SPLIT or ins.op == OP_TAIL_MATCH:
                    # ⛔ RANGE-CHECK BEFORE STAMPING.  `_onepass_addq` indexes
                    # `seen` by pc, so a malformed target must be caught HERE,
                    # not one iteration later at the top of the loop.
                    if ins.a < 0 or ins.a >= n or ins.b < 0 or ins.b >= n:
                        return OnePassVerdict(False, ONEPASS_BAD_TARGET, pc, -1, nalloc)
                    # `b` is the LOWER-priority alternative: stack it for after
                    # the `a` subtree, exactly as `_closure` orders them.
                    if not _onepass_addq(seen, gen, ins.b):
                        return OnePassVerdict(False, ONEPASS_MULTIPLE_PATHS, pc, ins.b, nalloc)
                    st_pc.append(ins.b)
                    st_caps.append(caps)
                    st_cond.append(cond)
                    if not _onepass_addq(seen, gen, ins.a):
                        return OnePassVerdict(False, ONEPASS_MULTIPLE_PATHS, pc, ins.a, nalloc)
                    pc = ins.a
                    continue
                if ins.op == OP_JMP:
                    if ins.a < 0 or ins.a >= n:
                        return OnePassVerdict(False, ONEPASS_BAD_TARGET, pc, ins.a, nalloc)
                    if not _onepass_addq(seen, gen, ins.a):
                        return OnePassVerdict(False, ONEPASS_MULTIPLE_PATHS, pc, ins.a, nalloc)
                    pc = ins.a
                    continue
                if ins.op == OP_SAVE:
                    if ins.a < n_slots:
                        caps |= (UInt64(1) << UInt64(ins.a))
                    if pc + 1 >= n:
                        return OnePassVerdict(False, ONEPASS_BAD_TARGET, pc, pc + 1, nalloc)
                    if not _onepass_addq(seen, gen, pc + 1):
                        return OnePassVerdict(False, ONEPASS_MULTIPLE_PATHS, pc, pc + 1, nalloc)
                    pc = pc + 1
                    continue
                if ins.op == OP_ASSERT:
                    # RE2 is deliberately conservative here: an EmptyWidth is
                    # assumed to proceed, and its flag joins the condition.
                    if ins.a >= 0 and ins.a < 6:
                        cond |= (UInt8(1) << UInt8(ins.a))
                    if pc + 1 >= n:
                        return OnePassVerdict(False, ONEPASS_BAD_TARGET, pc, pc + 1, nalloc)
                    if not _onepass_addq(seen, gen, pc + 1):
                        return OnePassVerdict(False, ONEPASS_MULTIPLE_PATHS, pc, pc + 1, nalloc)
                    pc = pc + 1
                    continue
                if ins.op == OP_MATCH:
                    if matched:
                        return OnePassVerdict(False, ONEPASS_MULTIPLE_MATCHES, pc, -1, nalloc)
                    matched = True
                    break
                # Consuming: OP_CHAR / OP_CLASS / OP_ANY.  Its successor is the
                # NEXT NODE (the Pike VM's `_add_thread_from(..., pc + 1, ...)`).
                var nxt = pc + 1
                if nxt >= n:
                    return OnePassVerdict(False, ONEPASS_BAD_TARGET, pc, nxt, nalloc)
                if node_of[nxt] < 0:
                    if nalloc >= ONEPASS_MAX_NODES:
                        return OnePassVerdict(False, ONEPASS_NODE_BUDGET, pc, nxt, nalloc)
                    node_of[nxt] = nalloc
                    nalloc += 1
                    tovisit.append(nxt)
                var newnext = node_of[nxt]
                var newcond = cond
                if matched:
                    newcond |= ONEPASS_MATCH_WINS
                for b in range(256):
                    if not _onepass_consumes(ins, classes, b):
                        continue
                    if act_next[b] < 0:
                        act_next[b] = newnext
                        act_caps[b] = caps
                        act_cond[b] = newcond
                    elif act_next[b] != newnext or act_caps[b] != caps or act_cond[b] != newcond:
                        # RE2: "Not OnePass: conflict on byte %#x at state %d".
                        return OnePassVerdict(False, ONEPASS_BYTE_CONFLICT, pc, b, nalloc)
                break

    return OnePassVerdict(True, ONEPASS_OK, -1, -1, nalloc)


# ---------------------------------------------------------------------------
# AST nodes.  We do build a tree; it keeps the compiler clean and the
# fragment-stitching correct.  Heap nodes via OwnedPointer.
# ---------------------------------------------------------------------------

comptime AST_EMPTY: UInt8 = 0      # matches the empty string
comptime AST_CHAR: UInt8 = 1       # literal byte (i_byte)
comptime AST_CLASS: UInt8 = 2      # char class (i_class index into classes list)
comptime AST_ANY: UInt8 = 3        # `.` (i_byte: 1 = dotall else 0)
comptime AST_ASSERT: UInt8 = 4     # zero-width assertion (i_byte = ASSERT_* kind)
comptime AST_CONCAT: UInt8 = 5     # seq of children
comptime AST_ALT: UInt8 = 6        # alternation of children
comptime AST_STAR: UInt8 = 7       # child* (i_byte: 1 = greedy)
comptime AST_PLUS: UInt8 = 8       # child+ (i_byte: 1 = greedy)
comptime AST_QUEST: UInt8 = 9      # child? (i_byte: 1 = greedy)
comptime AST_REPEAT: UInt8 = 10    # child{lo,hi}  (i_lo, i_hi (-1 = inf), i_byte: 1 = greedy)
comptime AST_GROUP: UInt8 = 11     # ( child )  capturing if i_lo >= 1 (= group index), else non-capturing


struct AstNode(Movable, Copyable):
    """A regex AST node.  Children are `ArcPointer` (refcount, Copyable) so
    the node itself is `Copyable` and storable in `List` — same pragmatic
    pattern as `WhenCaseData` in `expr.mojo`.  Trees are small (one node per
    pattern atom); the refcount traffic is negligible at compile time."""
    var kind: UInt8
    var i_byte: Int          # byte value / dotall flag / assert kind / greedy flag
    var i_class: Int         # class index (AST_CLASS)
    var i_lo: Int            # repeat lo / group index
    var i_hi: Int            # repeat hi (-1 = unbounded)
    var children: List[ArcPointer[AstNode]]

    def __init__(out self, kind: UInt8):
        self.kind = kind
        self.i_byte = 0
        self.i_class = 0
        self.i_lo = 0
        self.i_hi = 0
        self.children = List[ArcPointer[AstNode]]()

    def copy(self) -> Self:
        var n = AstNode(self.kind)
        n.i_byte = self.i_byte
        n.i_class = self.i_class
        n.i_lo = self.i_lo
        n.i_hi = self.i_hi
        for i in range(len(self.children)):
            n.children.append(ArcPointer(self.children[i][].copy()))
        return n^

    def add_child(mut self, var c: AstNode):
        self.children.append(ArcPointer(c^))


# ---------------------------------------------------------------------------
# Parser: pattern string -> AST (and a side list of ByteClass).
# ---------------------------------------------------------------------------

struct _Parser(Movable):
    var bytes: List[UInt8]
    var pos: Int
    var n: Int
    var flags: RegexFlags        # mutated by inline `(?i)` etc. (group-scoped)
    var classes: List[ByteClass]
    var n_groups: Int
    # group_names[k] is the name of capturing group (k+1), or "" if that group
    # is unnamed.  Length always == n_groups at end of parse.  Populated by the
    # `(?P<name>...)` syntax.  RE2 (and DuckDB) only accept the
    # Python-style `(?P<name>...)`; the Perl-style `(?<name>...)` is rejected.
    var group_names: List[String]

    def __init__(out self, pattern: String, flags: RegexFlags):
        self.bytes = List[UInt8]()
        var pb = pattern.as_bytes()
        for i in range(len(pb)):
            self.bytes.append(pb[i])
        self.pos = 0
        self.n = len(self.bytes)
        self.flags = flags.copy()
        self.classes = List[ByteClass]()
        self.n_groups = 0
        self.group_names = List[String]()

    @always_inline
    def peek(self) -> Int:
        if self.pos >= self.n:
            return -1
        return Int(self.bytes[self.pos])

    @always_inline
    def peek2(self) -> Int:
        if self.pos + 1 >= self.n:
            return -1
        return Int(self.bytes[self.pos + 1])

    @always_inline
    def advance(mut self) -> Int:
        if self.pos >= self.n:
            return -1
        var c = Int(self.bytes[self.pos])
        self.pos += 1
        return c

    @always_inline
    def at_end(self) -> Bool:
        return self.pos >= self.n

    def _skip_ws(mut self):
        if not self.flags.extended:
            return
        while not self.at_end():
            var c = self.peek()
            if c == ord(" ") or c == ord("\t") or c == ord("\n") or c == ord("\r"):
                _ = self.advance()
            elif c == ord("#"):
                while not self.at_end() and self.peek() != ord("\n"):
                    _ = self.advance()
            else:
                return

    def _add_class(mut self, cls: ByteClass) -> Int:
        var idx = len(self.classes)
        self.classes.append(cls)
        return idx

    # ---- alternation := concat ( '|' concat )* ----
    def parse_alt(mut self) raises -> AstNode:
        var first = self.parse_concat()
        self._skip_ws()
        if self.peek() != ord("|"):
            return first^
        var alt = AstNode(AST_ALT)
        alt.add_child(first^)
        while self.peek() == ord("|"):
            _ = self.advance()  # '|'
            var nxt = self.parse_concat()
            alt.add_child(nxt^)
            self._skip_ws()
        return alt^

    # ---- concat := quantified_atom* ----
    def parse_concat(mut self) raises -> AstNode:
        var seq = AstNode(AST_CONCAT)
        while True:
            self._skip_ws()
            var c = self.peek()
            if c == -1 or c == ord("|") or c == ord(")"):
                break
            var atom = self.parse_quantified_atom()
            if atom.kind == AST_EMPTY and atom.i_byte == 99:
                # sentinel: an inline `(?i)`-style flag toggle produced no
                # atom — skip it.
                continue
            seq.add_child(atom^)
        if len(seq.children) == 0:
            return AstNode(AST_EMPTY)
        if len(seq.children) == 1:
            # Unwrap a single-child concat.
            var only = seq.children.pop()
            return only[].copy()
        return seq^

    def parse_quantified_atom(mut self) raises -> AstNode:
        var atom = self.parse_atom()
        if atom.kind == AST_EMPTY and atom.i_byte == 99:
            return atom^  # flag-toggle sentinel
        self._skip_ws()
        var c = self.peek()
        if c == ord("*") or c == ord("+") or c == ord("?"):
            _ = self.advance()
            var greedy = True
            if self.peek() == ord("?"):
                _ = self.advance()
                greedy = False
            elif self.peek() == ord("*") or self.peek() == ord("+"):
                raise Error("regexp: bad repetition operator (adjacent quantifiers)")
            var kind: UInt8 = AST_STAR
            if c == ord("+"): kind = AST_PLUS
            elif c == ord("?"): kind = AST_QUEST
            var q = AstNode(kind)
            q.i_byte = 1 if greedy else 0
            q.add_child(atom^)
            return q^
        elif c == ord("{"):
            return self.parse_brace(atom^)
        return atom^

    def parse_brace(mut self, var atom: AstNode) raises -> AstNode:
        var save_pos = self.pos
        _ = self.advance()  # '{'
        var lo = self._parse_int_or_neg1()
        if lo < 0:
            # Not a valid `{n...` — treat `{` as a literal.
            self.pos = save_pos
            _ = self.advance()  # '{'
            # We "consumed" the atom but need to put it back into a concat
            # with a literal `{`.  Simpler: build a concat [atom, lit '{'].
            var seq = AstNode(AST_CONCAT)
            seq.add_child(atom^)
            var litn = AstNode(AST_CHAR)
            litn.i_byte = ord("{")
            seq.add_child(litn^)
            return seq^
        var hi: Int
        var c = self.peek()
        if c == ord("}"):
            _ = self.advance()
            hi = lo
        elif c == ord(","):
            _ = self.advance()
            if self.peek() == ord("}"):
                _ = self.advance()
                hi = -1
            else:
                hi = self._parse_int_or_neg1()
                if hi < 0 or self.peek() != ord("}"):
                    raise Error("regexp: invalid {n,m} quantifier")
                _ = self.advance()
        else:
            self.pos = save_pos
            _ = self.advance()  # '{'
            var seq2 = AstNode(AST_CONCAT)
            seq2.add_child(atom^)
            var litn2 = AstNode(AST_CHAR)
            litn2.i_byte = ord("{")
            seq2.add_child(litn2^)
            return seq2^
        if hi >= 0 and hi < lo:
            raise Error("regexp: invalid {n,m} quantifier: m < n")
        if lo > 1000 or hi > 1000:
            raise Error("regexp: {n,m} repetition count too large")
        var greedy = True
        if self.peek() == ord("?"):
            _ = self.advance()
            greedy = False
        elif self.peek() == ord("*") or self.peek() == ord("+"):
            raise Error("regexp: bad repetition operator (adjacent quantifiers)")
        var r = AstNode(AST_REPEAT)
        r.i_lo = lo
        r.i_hi = hi
        r.i_byte = 1 if greedy else 0
        r.add_child(atom^)
        return r^

    def _parse_int_or_neg1(mut self) -> Int:
        if self.peek() < ord("0") or self.peek() > ord("9"):
            return -1
        var v = 0
        while self.peek() >= ord("0") and self.peek() <= ord("9"):
            v = v * 10 + (self.advance() - ord("0"))
            if v > 100000:
                v = 100001
        return v

    # ---- atom ----
    def parse_atom(mut self) raises -> AstNode:
        self._skip_ws()
        var c = self.peek()
        if c == -1:
            return AstNode(AST_EMPTY)
        if c == ord("("):
            return self.parse_group()
        if c == ord("["):
            return self.parse_char_class()
        if c == ord("."):
            _ = self.advance()
            var a = AstNode(AST_ANY)
            a.i_byte = 1 if self.flags.dotall else 0
            return a^
        if c == ord("^"):
            _ = self.advance()
            var a = AstNode(AST_ASSERT)
            a.i_byte = Int(ASSERT_BOL if self.flags.multiline else ASSERT_BOS)
            return a^
        if c == ord("$"):
            _ = self.advance()
            var a = AstNode(AST_ASSERT)
            a.i_byte = Int(ASSERT_EOL if self.flags.multiline else ASSERT_EOS)
            return a^
        if c == ord("*") or c == ord("+") or c == ord("?"):
            raise Error("regexp: bad repetition operator (nothing to repeat)")
        if c == ord("\\"):
            return self.parse_escape_atom()
        # Plain literal byte.
        _ = self.advance()
        return self._emit_literal(c)

    def _emit_literal(mut self, b: Int) -> AstNode:
        if self.flags.case_insensitive and ((b >= ord("A") and b <= ord("Z")) or (b >= ord("a") and b <= ord("z"))):
            var cls = ByteClass()
            cls.add(b)
            if b >= ord("A") and b <= ord("Z"):
                cls.add(b + 32)
            else:
                cls.add(b - 32)
            var idx = self._add_class(cls)
            var n = AstNode(AST_CLASS)
            n.i_class = idx
            return n^
        var n = AstNode(AST_CHAR)
        n.i_byte = b
        return n^

    def parse_escape_atom(mut self) raises -> AstNode:
        _ = self.advance()  # '\'
        var c = self.peek()
        if c == -1:
            raise Error("regexp: trailing backslash in pattern")
        if c >= ord("1") and c <= ord("9"):
            raise Error("regexp: backreference in pattern is not supported")
        if c == ord("A"):
            _ = self.advance()
            var a = AstNode(AST_ASSERT); a.i_byte = Int(ASSERT_BOS); return a^
        if c == ord("z") or c == ord("Z"):
            _ = self.advance()
            var a = AstNode(AST_ASSERT); a.i_byte = Int(ASSERT_EOS); return a^
        if c == ord("b"):
            _ = self.advance()
            var a = AstNode(AST_ASSERT); a.i_byte = Int(ASSERT_WORD_B); return a^
        if c == ord("B"):
            _ = self.advance()
            var a = AstNode(AST_ASSERT); a.i_byte = Int(ASSERT_NOT_WORD_B); return a^
        if c == ord("d") or c == ord("D") or c == ord("w") or c == ord("W") or c == ord("s") or c == ord("S"):
            _ = self.advance()
            var cls = self._predefined_class(c)
            if self.flags.case_insensitive:
                cls.add_case_folded()
            var idx = self._add_class(cls)
            var n = AstNode(AST_CLASS); n.i_class = idx; return n^
        # Escaped metacharacter / control char -> literal.
        var b = self._escaped_char_byte(c)
        _ = self.advance()
        return self._emit_literal(b)

    def _predefined_class(self, c: Int) -> ByteClass:
        if c == ord("d"):
            return _digit_class()
        if c == ord("D"):
            var cl = _digit_class(); cl.negate(); return cl
        if c == ord("w"):
            return _word_class()
        if c == ord("W"):
            var cl = _word_class(); cl.negate(); return cl
        if c == ord("s"):
            return _space_class()
        var cl = _space_class(); cl.negate(); return cl

    def _escaped_char_byte(self, c: Int) -> Int:
        if c == ord("n"): return 10
        if c == ord("r"): return 13
        if c == ord("t"): return 9
        if c == ord("f"): return 12
        if c == ord("v"): return 11
        if c == ord("a"): return 7
        if c == ord("0"): return 0
        return c  # \. \* \\ \( etc. -> the char itself

    def _read_group_name(mut self) raises -> String:
        """Read a capture-group name `[A-Za-z_][A-Za-z0-9_]*` followed by `>`.
        Called after consuming `(?P<` (the `<` already consumed).  Returns the
        name; raises on an empty / malformed name or a missing `>`."""
        var name = String("")
        var first = True
        while True:
            var c = self.peek()
            if c == -1:
                raise Error("regexp: unterminated named group (missing '>')")
            if c == ord(">"):
                _ = self.advance()
                break
            var is_alpha = (c >= ord("a") and c <= ord("z")) or (c >= ord("A") and c <= ord("Z")) or c == ord("_")
            var is_digit = c >= ord("0") and c <= ord("9")
            if not (is_alpha or (not first and is_digit)):
                raise Error("regexp: invalid named-group name character at offset " + String(self.pos))
            _ = self.advance()
            name += chr(c)
            first = False
        if name.byte_length() == 0:
            raise Error("regexp: empty named-group name")
        return name^

    def parse_group(mut self) raises -> AstNode:
        _ = self.advance()  # '('
        var capturing = True
        var group_idx = 0
        var group_name = String("")
        var saved_flags = self.flags.copy()
        if self.peek() == ord("?"):
            _ = self.advance()  # '?'
            var c = self.peek()
            if c == ord(":"):
                _ = self.advance()
                capturing = False
            elif c == ord("P"):
                # `(?P<name>...)` — Python-style named capture group (the form
                # RE2 / DuckDB accept).  `(?P=name)` (backref) is unsupported.
                _ = self.advance()  # 'P'
                if self.peek() != ord("<"):
                    raise Error("regexp: expected '<' after '(?P' (named-group syntax is '(?P<name>...)')")
                _ = self.advance()  # '<'
                group_name = self._read_group_name()
                # capturing stays True; falls through to the `if capturing:` below.
            elif c == ord("<"):
                # `(?<name>...)` (Perl/.NET) and `(?<=...)`/`(?<!...)`
                # (lookbehind) are NOT supported by RE2 -> DuckDB rejects them
                # ("invalid perl operator: (?<").  We match that.  Use the
                # Python-style `(?P<name>...)` for named groups.
                raise Error("regexp: invalid perl operator: (?< — use (?P<name>...) for named capture groups")
            elif c == ord("=") or c == ord("!"):
                raise Error("regexp: lookahead/lookbehind is not supported")
            elif c == ord(">"):
                raise Error("regexp: atomic groups are not supported")
            else:
                # Flag toggle: (?imsx) [inline, no body] or (?imsx:...) [scoped].
                capturing = False
                var negate = False
                var scoped: Bool
                while True:
                    var fc = self.peek()
                    if fc == ord("-"):
                        _ = self.advance(); negate = True
                    elif fc == ord("i"):
                        _ = self.advance(); self.flags.case_insensitive = not negate
                    elif fc == ord("m"):
                        _ = self.advance(); self.flags.multiline = not negate
                    elif fc == ord("s"):
                        _ = self.advance(); self.flags.dotall = not negate
                    elif fc == ord("x"):
                        _ = self.advance(); self.flags.extended = not negate
                    elif fc == ord(":"):
                        _ = self.advance(); scoped = True; break
                    elif fc == ord(")"):
                        _ = self.advance()
                        # Inline `(?i)` — flags persist for the rest of the
                        # enclosing group.  Return a sentinel "empty"
                        # node that parse_concat skips.
                        var s = AstNode(AST_EMPTY); s.i_byte = 99; return s^
                    else:
                        raise Error("regexp: invalid (?...) group specifier")
                # scoped: compile body with current flags, restore at ')'.
                _ = scoped
        if capturing:
            self.n_groups += 1
            group_idx = self.n_groups
            # group_names is parallel to all capturing groups: index k holds
            # group (k+1)'s name ("" if unnamed).  A duplicate name is accepted
            # (RE2/DuckDB tolerate it; we record it but don't expose by-name
            # lookup — there is no by-name extract API).
            self.group_names.append(group_name^)
        var body = self.parse_alt()
        if self.peek() != ord(")"):
            raise Error("regexp: unbalanced parentheses (missing ')')")
        _ = self.advance()  # ')'
        # Restore flags (scopes any inline `(?i)` toggle to the group, which
        # is RE2's behavior; for `(?:...)` / `(...)` this is a no-op).
        self.flags = saved_flags
        var g = AstNode(AST_GROUP)
        g.i_lo = group_idx  # 0 = non-capturing
        g.add_child(body^)
        return g^

    def parse_char_class(mut self) raises -> AstNode:
        _ = self.advance()  # '['
        var cls = ByteClass()
        var negated = False
        if self.peek() == ord("^"):
            _ = self.advance()
            negated = True
        var first = True
        while True:
            var c = self.peek()
            if c == -1:
                raise Error("regexp: unterminated character class")
            if c == ord("]") and not first:
                _ = self.advance()
                break
            first = False
            if c == ord("[") and self.peek2() == ord(":"):
                self._parse_posix_class(cls)
                continue
            if c == ord("\\"):
                _ = self.advance()
                var ec = self.peek()
                if ec == -1:
                    raise Error("regexp: trailing backslash in character class")
                if ec == ord("d") or ec == ord("D") or ec == ord("w") or ec == ord("W") or ec == ord("s") or ec == ord("S"):
                    _ = self.advance()
                    cls.union_with(self._predefined_class(ec))
                    continue
                var lo_byte = self._escaped_char_byte(ec)
                _ = self.advance()
                if self.peek() == ord("-") and self.peek2() != ord("]") and self.peek2() != -1:
                    _ = self.advance()  # '-'
                    var hi_byte = self._read_class_member()
                    if hi_byte < lo_byte:
                        raise Error("regexp: invalid range in character class")
                    cls.add_range(lo_byte, hi_byte)
                else:
                    cls.add(lo_byte)
                continue
            _ = self.advance()
            var lo_byte2 = c
            if self.peek() == ord("-") and self.peek2() != ord("]") and self.peek2() != -1:
                _ = self.advance()  # '-'
                var hi_byte2 = self._read_class_member()
                if hi_byte2 < lo_byte2:
                    raise Error("regexp: invalid range in character class")
                cls.add_range(lo_byte2, hi_byte2)
            else:
                cls.add(lo_byte2)
        if negated:
            cls.negate()
        if self.flags.case_insensitive:
            cls.add_case_folded()
        var idx = self._add_class(cls)
        var n = AstNode(AST_CLASS); n.i_class = idx; return n^

    def _read_class_member(mut self) raises -> Int:
        var c = self.peek()
        if c == -1:
            raise Error("regexp: unterminated character class")
        if c == ord("\\"):
            _ = self.advance()
            var ec = self.peek()
            if ec == -1:
                raise Error("regexp: trailing backslash in character class")
            _ = self.advance()
            return self._escaped_char_byte(ec)
        _ = self.advance()
        return c

    def _parse_posix_class(mut self, mut cls: ByteClass) raises:
        _ = self.advance()  # '['
        _ = self.advance()  # ':'
        var name = String("")
        while True:
            var c = self.peek()
            if c == -1:
                raise Error("regexp: unterminated POSIX character class")
            if c == ord(":"):
                break
            name += chr(c)
            _ = self.advance()
        _ = self.advance()  # ':'
        if self.peek() != ord("]"):
            raise Error("regexp: malformed POSIX character class")
        _ = self.advance()  # ']'
        var pc = ByteClass()
        if name == "alpha":
            pc.add_range(ord("A"), ord("Z")); pc.add_range(ord("a"), ord("z"))
        elif name == "digit":
            pc.add_range(ord("0"), ord("9"))
        elif name == "alnum":
            pc.add_range(ord("0"), ord("9")); pc.add_range(ord("A"), ord("Z")); pc.add_range(ord("a"), ord("z"))
        elif name == "upper":
            pc.add_range(ord("A"), ord("Z"))
        elif name == "lower":
            pc.add_range(ord("a"), ord("z"))
        elif name == "space":
            pc.union_with(_space_class())
        elif name == "blank":
            pc.add(ord(" ")); pc.add(ord("\t"))
        elif name == "punct":
            pc.add_range(0x21, 0x2F); pc.add_range(0x3A, 0x40); pc.add_range(0x5B, 0x60); pc.add_range(0x7B, 0x7E)
        elif name == "xdigit":
            pc.add_range(ord("0"), ord("9")); pc.add_range(ord("A"), ord("F")); pc.add_range(ord("a"), ord("f"))
        elif name == "cntrl":
            pc.add_range(0x00, 0x1F); pc.add(0x7F)
        elif name == "print":
            pc.add_range(0x20, 0x7E)
        elif name == "graph":
            pc.add_range(0x21, 0x7E)
        elif name == "word":
            pc.union_with(_word_class())
        else:
            raise Error("regexp: unknown POSIX character class [:" + name + ":]")
        cls.union_with(pc)


# ---------------------------------------------------------------------------
# Compiler: AST -> instruction fragments -> a flat program.
# A fragment is a List[Inst] whose internal JMP/SPLIT targets are 0-relative
# to the fragment start.  Stitching = append + (rebase targets by offset).
# ---------------------------------------------------------------------------

def _rebase(var frag: List[Inst], offset: Int) -> List[Inst]:
    for i in range(len(frag)):
        ref ins = frag[i]
        if ins.op == OP_JMP:
            ins.a += offset
        elif ins.op == OP_SPLIT:
            ins.a += offset
            ins.b += offset
    return frag^


def _concat_frags(var a: List[Inst], var b: List[Inst]) -> List[Inst]:
    var alen = len(a)
    var out = a^
    var bb = _rebase(b^, alen)
    for i in range(len(bb)):
        out.append(bb[i].copy())
    return out^


def _compile_node(node: AstNode) raises -> List[Inst]:
    """Compile an AST node into a 0-relative instruction fragment."""
    var out = List[Inst]()
    if node.kind == AST_EMPTY:
        return out^
    if node.kind == AST_CHAR:
        out.append(Inst(OP_CHAR, node.i_byte, 0))
        return out^
    if node.kind == AST_CLASS:
        out.append(Inst(OP_CLASS, node.i_class, 0))
        return out^
    if node.kind == AST_ANY:
        out.append(Inst(OP_ANY, node.i_byte, 0))
        return out^
    if node.kind == AST_ASSERT:
        out.append(Inst(OP_ASSERT, node.i_byte, 0))
        return out^
    if node.kind == AST_GROUP:
        var inner = _compile_node(node.children[0][])
        if node.i_lo >= 1:
            # capturing: SAVE 2g ; inner ; SAVE 2g+1
            var g = node.i_lo
            var pre = List[Inst]()
            pre.append(Inst(OP_SAVE, 2 * g, 0))
            var body = _concat_frags(pre^, inner^)
            body.append(Inst(OP_SAVE, 2 * g + 1, 0))
            return body^
        return inner^
    if node.kind == AST_CONCAT:
        for i in range(len(node.children)):
            var frag = _compile_node(node.children[i][])
            out = _concat_frags(out^, frag^)
        return out^
    if node.kind == AST_ALT:
        # alt(e1, e2, ..., en) =
        #   SPLIT 1, X1
        #   <e1> ; JMP END
        #   X1: SPLIT (X1+1), X2
        #   <e2> ; JMP END
        #   ...
        #   <en>
        #   END:
        var nb = len(node.children)
        if nb == 1:
            return _compile_node(node.children[0][])
        # Build incrementally.  We need the END position which is known only
        # after laying everything out — so we build a fragment and patch the
        # JMPs at the end.
        var prog = List[Inst]()
        var jmp_sites = List[Int]()
        var i = 0
        while i < nb:
            if i < nb - 1:
                var split_idx = len(prog)
                prog.append(Inst(OP_SPLIT, 0, 0))
                var body_start = len(prog)
                var body = _rebase(_compile_node(node.children[i][]), body_start)
                for k in range(len(body)):
                    prog.append(body[k].copy())
                var jmp_idx = len(prog)
                prog.append(Inst(OP_JMP, 0, 0))
                jmp_sites.append(jmp_idx)
                var after = len(prog)
                prog[split_idx].a = body_start
                prog[split_idx].b = after
            else:
                var body_start = len(prog)
                var body = _rebase(_compile_node(node.children[i][]), body_start)
                for k in range(len(body)):
                    prog.append(body[k].copy())
            i += 1
        var end_pos = len(prog)
        for k in range(len(jmp_sites)):
            prog[jmp_sites[k]].a = end_pos
        return prog^
    if node.kind == AST_QUEST:
        # greedy: SPLIT body, after ; body ; after:
        # non-greedy: SPLIT after, body ; body ; after:
        var greedy = node.i_byte == 1
        var inner = _rebase(_compile_node(node.children[0][]), 1)
        var prog = List[Inst]()
        prog.append(Inst(OP_SPLIT, 0, 0))
        for k in range(len(inner)):
            prog.append(inner[k].copy())
        var after = len(prog)
        if greedy:
            prog[0].a = 1
            prog[0].b = after
        else:
            prog[0].a = after
            prog[0].b = 1
        return prog^
    if node.kind == AST_STAR:
        # greedy: L1: SPLIT body, after ; body ; JMP L1 ; after:
        # non-greedy: L1: SPLIT after, body ; body ; JMP L1 ; after:
        var greedy = node.i_byte == 1
        var inner = _rebase(_compile_node(node.children[0][]), 1)
        var prog = List[Inst]()
        prog.append(Inst(OP_SPLIT, 0, 0))  # L1 == 0
        for k in range(len(inner)):
            prog.append(inner[k].copy())
        prog.append(Inst(OP_JMP, 0, 0))   # back to L1
        var after = len(prog)
        if greedy:
            prog[0].a = 1
            prog[0].b = after
        else:
            prog[0].a = after
            prog[0].b = 1
        return prog^
    if node.kind == AST_PLUS:
        # body ; SPLIT body_start, after  (greedy)  /  SPLIT after, body_start (non-greedy)
        var greedy = node.i_byte == 1
        var inner = _compile_node(node.children[0][])
        var prog = inner^
        var split_idx = len(prog)
        prog.append(Inst(OP_SPLIT, 0, 0))
        var after = len(prog)
        if greedy:
            prog[split_idx].a = 0
            prog[split_idx].b = after
        else:
            prog[split_idx].a = after
            prog[split_idx].b = 0
        return prog^
    if node.kind == AST_REPEAT:
        var greedy = node.i_byte == 1
        var lo = node.i_lo
        var hi = node.i_hi
        var prog = List[Inst]()
        # `lo` mandatory copies.
        for _ in range(lo):
            var c = _compile_node(node.children[0][])
            prog = _concat_frags(prog^, c^)
        if hi < 0:
            # {lo,} == lo copies then `child*`.
            var star = AstNode(AST_STAR)
            star.i_byte = node.i_byte
            star.add_child(node.children[0][].copy())
            var sf = _compile_node(star^)
            prog = _concat_frags(prog^, sf^)
        else:
            # {lo,hi} == lo copies then (hi-lo) optional copies, each guarded
            # by a SPLIT that, greedily, prefers to take the copy.  Layout:
            #   SPLIT body1, END
            #   <body1>
            #   SPLIT body2, END
            #   <body2>
            #   ...
            #   END:
            var extra = hi - lo
            var splice_start = len(prog)
            _ = splice_start
            var jmp_after_sites = List[Int]()
            _ = jmp_after_sites
            var split_sites = List[Int]()
            var k2 = 0
            while k2 < extra:
                var split_idx = len(prog)
                prog.append(Inst(OP_SPLIT, 0, 0))
                split_sites.append(split_idx)
                var body_start = len(prog)
                var body = _rebase(_compile_node(node.children[0][]), body_start)
                for kk in range(len(body)):
                    prog.append(body[kk].copy())
                k2 += 1
            var end_pos = len(prog)
            for si_i in range(len(split_sites)):
                var si = split_sites[si_i]
                if greedy:
                    prog[si].a = si + 1
                    prog[si].b = end_pos
                else:
                    prog[si].a = end_pos
                    prog[si].b = si + 1
        return prog^
    raise Error("regexp: internal compiler error: unknown AST node kind " + String(Int(node.kind)))


# ---------------------------------------------------------------------------
# The compiled program (the public type).
# ---------------------------------------------------------------------------

struct RegexProgram(Movable, Copyable):
    """A compiled regex program. Build once per pattern via `.compile(...)`.

    PERF: programs are compiled per batch — see the PERF note in
    `regexp_functions.mojo` on compile-once-per-plan.
    """
    var prog: List[Inst]
    var classes: List[ByteClass]
    var n_groups: Int           # number of capturing groups (0 = none)
    var n_slots: Int            # = (n_groups + 1) * 2 capture slots
    var flags: RegexFlags
    var pattern_src: String     # kept for diagnostics
    # group_names[k] = the name of capturing group (k+1), "" if unnamed
    # (`(?P<name>...)` syntax).  len == n_groups.  The names are only RECORDED
    # (the pattern parses cleanly); there is no `group="name"` extract API —
    # `group_index_for_name` is the lookup such an API would use.
    var group_names: List[String]
    # Where this program CAN begin matching -- ANCHOR_NONE / _BOS / _BOL.
    # Derived from `prog` in `__init__`, so every construction site (including
    # `copy()`) gets it for free and it can never drift from the instructions.
    var start_anchor: UInt8

    def __init__(out self, var prog: List[Inst], var classes: List[ByteClass], n_groups: Int, var flags: RegexFlags, var pattern_src: String, var group_names: List[String]):
        # ⭐ THE FUSED TAIL, before the anchor classification so the classifier sees the
        # program the VM will actually run.  Both derivations live HERE rather
        # than in `compile()` so that every construction site -- `copy()`
        # included -- gets them, and neither can drift from the instructions.
        # `_install_dotstar_eos_tail` is idempotent, which is what makes running
        # it again on an already-fused program (exactly what `copy()` does) a
        # no-op rather than a second rewrite.
        _install_dotstar_eos_tail(prog)
        self.start_anchor = classify_start_anchor(prog)
        self.prog = prog^
        self.classes = classes^
        self.n_groups = n_groups
        self.n_slots = (n_groups + 1) * 2
        self.flags = flags^
        self.pattern_src = pattern_src^
        self.group_names = group_names^

    def copy(self) -> Self:
        var p = List[Inst]()
        for i in range(len(self.prog)):
            p.append(self.prog[i].copy())
        var c = List[ByteClass]()
        for i in range(len(self.classes)):
            c.append(self.classes[i])
        var gn = List[String]()
        for i in range(len(self.group_names)):
            gn.append(self.group_names[i].copy())
        return Self(p^, c^, self.n_groups, self.flags.copy(), self.pattern_src.copy(), gn^)

    def group_index_for_name(self, name: String) -> Int:
        """Return the 1-based index of capturing group `name`, or -1 if there is
        no such named group.  (First match wins on a duplicate name — RE2's
        behavior.)  Provided for a `group="name"` extract API; no extract
        function uses it."""
        for k in range(len(self.group_names)):
            if self.group_names[k] == name:
                return k + 1
        return -1

    def one_pass(self) -> OnePassVerdict:
        """Does this program admit a deterministic one-pass automaton?

        STATIC ONLY -- see `one_pass_verdict`.  Nothing in the match path
        consults this; it exists so the question can be ANSWERED before an
        engine is built on the answer.
        """
        return one_pass_verdict(self.prog, self.classes, self.n_slots)

    @staticmethod
    def compile(pattern: String, flags_str: String = "") raises -> RegexProgram:
        var flags = parse_flags_string(flags_str)
        var parser = _Parser(pattern, flags)
        var ast = parser.parse_alt()
        if not parser.at_end():
            var rem = parser.peek()
            if rem == ord(")"):
                raise Error("regexp: unbalanced parentheses (extra ')')")
            raise Error("regexp: trailing characters in pattern at offset " + String(parser.pos))
        # Wrap in group 0: SAVE 0 ; <ast> ; SAVE 1 ; MATCH.
        var body = _compile_node(ast)
        var prog = List[Inst]()
        prog.append(Inst(OP_SAVE, 0, 0))
        var rebased = _rebase(body^, 1)
        for i in range(len(rebased)):
            prog.append(rebased[i].copy())
        prog.append(Inst(OP_SAVE, 1, 0))
        prog.append(Inst(OP_MATCH, 0, 0))
        # Copy `classes` out of the (about-to-be-dropped) parser — compile
        # time, not perf-critical; sidesteps the partial-move-from-`parser`.
        var n_groups = parser.n_groups
        var classes_out = List[ByteClass]()
        for ci in range(len(parser.classes)):
            classes_out.append(parser.classes[ci])
        var names_out = List[String]()
        for gi in range(len(parser.group_names)):
            names_out.append(parser.group_names[gi].copy())
        return RegexProgram(prog^, classes_out^, n_groups, flags^, pattern.copy(), names_out^)

    @always_inline
    def _class_matches(self, class_idx: Int, b: Int) -> Bool:
        return self.classes[class_idx].contains(b)

    # -----------------------------------------------------------------------
    # The Pike VM.  Unanchored search: a fresh "start" thread is seeded at
    # every byte position >= `min_start` until a match is found (leftmost).
    # Passing the full subject + min_start (rather than slicing) preserves
    # the `\A` / `^` / `\b` context at the search-start boundary — important
    # for find_all / regexp_replace where a `^`-anchored pattern must not
    # re-match in the middle of the string.
    # -----------------------------------------------------------------------

    # ⭐ CALLER-OWNED SCRATCH.  Every method below comes in three spellings
    # and they are ONE implementation:
    #
    #   `..._with(span, …, mut scratch)`  — the real one.  ZERO heap traffic of
    #        its own: the subject is a BORROWED `Span` over the caller's bytes
    #        (no per-row `List[UInt8]` copy) and the Pike VM's two thread lists
    #        live in the CALLER's `RegexScratch` (no per-row `_ThreadList`
    #        construction).  A columnar kernel makes ONE scratch per column and
    #        reuses it for every row.
    #   `...(span)`                        — a one-shot: builds a scratch, runs.
    #   `...(list)`                        — the pre-existing `List[UInt8]`
    #        spelling, kept verbatim so every existing caller and every pinned
    #        test compiles and means exactly what it meant before.
    #
    # ⛔ THE SCRATCH CARRIES NO STATE ACROSS ROWS AND MUST NOT.  `_run_with`
    # `reset()`s both thread lists on entry; `reset()` bumps a GENERATION stamp,
    # so a `seen` mark from the previous ROW can never be read as seen in this
    # one (stamps only ever equal the CURRENT gen).  A differential test is the
    # falsifier: it runs a whole column through
    # one scratch and demands byte-equality with the one-shot spelling row by
    # row, which is what a leaked thread, a stale slot or a stale stamp breaks.

    def is_match(self, subject: Span[UInt8, _]) -> Bool:
        var sc = RegexScratch()
        return self.is_match_with(subject, sc)

    def is_match(self, subject: List[UInt8]) -> Bool:
        return self.is_match(Span(subject))

    def is_match_with(self, subject: Span[UInt8, _], mut sc: RegexScratch) -> Bool:
        var r = self._run_with(subject, 0, False, sc.clist, sc.nlist, sc.match_slots)
        return r.matched

    def find(self, subject: Span[UInt8, _]) -> RegexMatch:
        var sc = RegexScratch()
        return self.find_with(subject, sc)

    def find(self, subject: List[UInt8]) -> RegexMatch:
        return self.find(Span(subject))

    def find_with(self, subject: Span[UInt8, _], mut sc: RegexScratch) -> RegexMatch:
        return self.find_from_with_engine(subject, 0, sc, REGEX_ENGINE_AUTO)

    def find_from(self, subject: Span[UInt8, _], start: Int) -> RegexMatch:
        var sc = RegexScratch()
        return self.find_from_with(subject, start, sc)

    def find_from(self, subject: List[UInt8], start: Int) -> RegexMatch:
        return self.find_from(Span(subject), start)

    def find_from_with(self, subject: Span[UInt8, _], start: Int, mut sc: RegexScratch) -> RegexMatch:
        # Leftmost match at or after byte offset `start`.  Used by
        # find_all / regexp_replace.
        return self.find_from_with_engine(subject, start, sc, REGEX_ENGINE_AUTO)

    def find_from_with_engine(self, subject: Span[UInt8, _], start: Int, mut sc: RegexScratch, engine: UInt8) -> RegexMatch:
        """`find_from_with`, with the engine named.  Production passes
        `REGEX_ENGINE_AUTO`: BitState when `bitstate_fits(prog_len, text_len)`
        (RE2's own policy for a capture call on a small text), the Pike VM
        otherwise.  `_PIKE` / `_BITSTATE` pin one engine -- they exist for the
        differential test, which must run both over the same inputs.  Every
        engine returns the same `RegexMatch`, slot for slot."""
        if start > len(subject):
            return RegexMatch()
        var use_bitstate = engine == REGEX_ENGINE_BITSTATE or (
            engine == REGEX_ENGINE_AUTO
            and bitstate_fits(len(self.prog), len(subject) - start)
        )
        if not use_bitstate:
            return self._run_with(subject, start, True, sc.clist, sc.nlist, sc.match_slots)
        var result = RegexMatch()
        if bitstate_search(self, subject, start, sc.bits, sc.match_slots):
            result.matched = True
            result.start = sc.match_slots[0]
            result.end = sc.match_slots[1]
            # `match_slots` is the caller's scratch — copy, do not move.
            result.slots = sc.match_slots.copy()
        return result^

    def find_all_in(self, subject: Span[UInt8, _]) -> List[RegexMatch]:
        var sc = RegexScratch()
        return self.find_all_in_with(subject, sc)

    def find_all_in(self, subject: List[UInt8]) -> List[RegexMatch]:
        return self.find_all_in(Span(subject))

    def find_all_in_with(self, subject: Span[UInt8, _], mut sc: RegexScratch) -> List[RegexMatch]:
        var out = List[RegexMatch]()
        var pos = 0
        var n = len(subject)
        while pos <= n:
            var m = self.find_from_with(subject, pos, sc)
            if not m.matched:
                break
            out.append(m.copy())
            if m.end > pos:
                pos = m.end
            else:
                pos += 1
        return out^

    def _run(self, subject: Span[UInt8, _], min_start: Int, want_captures: Bool) -> RegexMatch:
        """One-shot: a fresh scratch, then `_run_with`.  Every per-row caller
        should hoist the scratch instead — see `RegexScratch`."""
        var sc = RegexScratch()
        return self._run_with(subject, min_start, want_captures, sc.clist, sc.nlist, sc.match_slots)

    def _run_with(
        self,
        subject: Span[UInt8, _],
        min_start: Int,
        want_captures: Bool,
        mut clist: _ThreadList,
        mut nlist: _ThreadList,
        mut match_slots: List[Int],
    ) -> RegexMatch:
        # Pike VM.  Thread = (pc, slots[nslots]).  Two thread lists; a
        # "seen-this-step" pc set to bound thread count to O(prog_len).
        # Leftmost-first priority = the order threads are added.
        var prog_len = len(self.prog)
        var n = len(subject)
        var nslots = self.n_slots if want_captures else 2

        # ⭐ CALLER-OWNED SCRATCH.  The two thread lists and the match-slot vector
        # are the CALLER's. Constructing them here, once per ROW, would cost five
        # `List` allocations plus an O(prog_len) zero-fill of `seen_gen` per row —
        # tens of millions of times on a large URL column, to run a
        # ~40-instruction program over an ~80-byte subject.  Re-arming them is a
        # `clear()` + a generation bump, which keeps every heap block the previous
        # row already grew.
        if len(clist.seen_gen) != prog_len:
            clist = _ThreadList(prog_len)
        if len(nlist.seen_gen) != prog_len:
            nlist = _ThreadList(prog_len)
        clist.reset()
        nlist.reset()
        var matched = False
        match_slots.clear()
        for _ in range(nslots):
            match_slots.append(-1)

        # ⭐ THE SEED FILTER (see `classify_start_anchor`).  For an anchored
        # program every seed away from a line start is doomed, and it is doomed
        # only AFTER allocating `init_slots` and walking the closure -- ~40% of
        # the regexp CPU on an anchored URL pattern.  `anchor` is derived once at
        # compile time and is `ANCHOR_NONE` for everything that is not provably
        # start-anchored, so the unanchored search is bit-for-bit unchanged.
        var anchor = self.start_anchor
        var sp = min_start
        while True:
            # Seed an unanchored start thread at sp (only while no match yet,
            # sp >= min_start, and the program's start anchor can hold here).
            if not matched and sp >= min_start and _seed_can_survive(anchor, subject, sp):
                self._seed_thread(clist, nslots, subject, sp, n)
            var b = Int(subject[sp]) if sp < n else -1
            var ti = 0
            while ti < clist.count:
                var pc = clist.pcs[ti]
                var base = ti * nslots     # this thread's slots in `slots_flat`
                var ins = self.prog[pc]
                var consumed = False
                if ins.op == OP_CHAR:
                    if b == ins.a:
                        consumed = True
                elif ins.op == OP_CLASS:
                    if b >= 0 and self._class_matches(ins.a, b):
                        consumed = True
                elif ins.op == OP_ANY:
                    if b >= 0 and (ins.a == 1 or b != 10):
                        consumed = True
                elif ins.op == OP_MATCH:
                    # Leftmost-first: the first MATCH thread in priority order
                    # wins this step; lower-priority threads after it are cut
                    # (they represent later-starting / less-preferred matches).
                    matched = True
                    for k in range(nslots):
                        match_slots[k] = clist.slots_flat[base + k]
                    break  # cut remaining lower-priority threads this step
                if consumed:
                    self._add_thread_from(nlist, pc + 1, clist.slots_flat, base, nslots, subject, sp + 1, n)
                ti += 1
            if sp >= n:
                break
            sp += 1
            clist.reset()
            swap(clist, nlist)
            if clist.count == 0 and matched:
                break
            # If clist is empty and no match yet, the top-of-loop seed will
            # restart the search at the new sp -- so for an ANCHORED program we
            # already know where (or whether) that can happen, and walking the
            # bytes in between is pure waste.  `sp >= 1` here, always.
            if clist.count == 0 and not matched and anchor != ANCHOR_NONE:
                if anchor == ANCHOR_BOS:
                    # Only position 0 could ever seed, and it is behind us.
                    break
                var nxt = sp
                while nxt <= n and Int(subject[nxt - 1]) != 10:
                    nxt += 1
                if nxt > n:
                    break            # no further line start: nothing can match
                if nxt != sp:
                    # ⛔ `clist.seen` is stamped for the epsilon walk performed
                    # at the OLD position and ASSERT outcomes are
                    # position-dependent, so it may not be carried across a
                    # jump.  (It is legitimately carried across a +1 step: the
                    # threads it describes live at that same position.)
                    clist.reset()
                    sp = nxt

        var result = RegexMatch()
        result.matched = matched
        if matched:
            result.start = match_slots[0]
            result.end = match_slots[1]
            if want_captures:
                # `match_slots` is the caller's scratch now — copy, do not move.
                result.slots = match_slots.copy()
            else:
                result.slots = List[Int]()
        return result^

    def _seed_thread(self, mut tl: _ThreadList, nslots: Int, subject: Span[UInt8, _], pos: Int, n: Int):
        """Add the start thread (pc 0, all slots unset) at `pos`."""
        tl.stack_pc.clear()
        tl.stack_slots.clear()
        tl.stack_pc.append(0)
        for _ in range(nslots):
            tl.stack_slots.append(-1)
        self._closure(tl, nslots, subject, pos, n)

    def _add_thread_from(self, mut tl: _ThreadList, pc: Int, src: List[Int], src_base: Int, nslots: Int, subject: Span[UInt8, _], pos: Int, n: Int):
        """Add a thread at `pc` whose slots are `src[src_base : +nslots]`.

        ⚠ `src` is the OTHER thread list's `slots_flat`, never `tl`'s -- `_run`
        always steps `clist` into `nlist`.  Passing a (list, base) pair instead
        of a `List[Int]` is the whole point: a `List[Int]` copy would be an
        allocation per surviving thread per byte position.
        """
        tl.stack_pc.clear()
        tl.stack_slots.clear()
        tl.stack_pc.append(pc)
        for k in range(nslots):
            tl.stack_slots.append(src[src_base + k])
        self._closure(tl, nslots, subject, pos, n)

    def _closure(self, mut tl: _ThreadList, nslots: Int, subject: Span[UInt8, _], pos: Int, n: Int):
        """Epsilon closure over `tl`'s scratch stacks.

        Follows JMP / SPLIT / SAVE / ASSERT until a consuming instruction or
        MATCH and adds those to the thread list.  The per-pc `seen` stamp
        prevents exponential duplication; the FIRST add of a pc wins priority,
        which is what makes the match leftmost-first.

        ⛔ THE STACK INVARIANT IS LOAD-BEARING.  `stack_slots` holds `nslots`
        ints per `stack_pc` entry, so the popped pc's slots always begin at
        `len(stack_slots) - nslots`.  Every arm below either leaves that region
        in place (it becomes the successor's), appends exactly one more region
        (SPLIT), or truncates it (a dead or emitted thread).
        """
        while len(tl.stack_pc) > 0:
            var cur_pc = tl.stack_pc.pop()
            var sbase = len(tl.stack_slots) - nslots
            if tl.is_seen(cur_pc):
                tl.stack_slots.resize(sbase, 0)
                continue
            tl.mark_seen(cur_pc)
            var ins = self.prog[cur_pc]
            if ins.op == OP_JMP:
                # Slots are inherited unchanged by the jump target.
                tl.stack_pc.append(ins.a)
            elif ins.op == OP_SPLIT:
                # a = higher priority; push b first so a is popped first.  The
                # region already at `sbase` becomes b's; a gets the duplicate on
                # top.  They are equal, so which one is "the original" does not
                # matter -- only the pc order does.
                tl.stack_pc.append(ins.b)
                tl.stack_pc.append(ins.a)
                for k in range(nslots):
                    var v = tl.stack_slots[sbase + k]
                    tl.stack_slots.append(v)
            elif ins.op == OP_SAVE:
                # In-place: this region is uniquely owned by this stack entry
                # (a SPLIT is the only thing that ever shares, and it copies).
                if ins.a < nslots:
                    tl.stack_slots[sbase + ins.a] = pos
                tl.stack_pc.append(cur_pc + 1)
            elif ins.op == OP_ASSERT:
                if self._assert_holds(ins.a, subject, pos, n):
                    tl.stack_pc.append(cur_pc + 1)
                else:
                    tl.stack_slots.resize(sbase, 0)   # thread dies
            elif ins.op == OP_TAIL_MATCH:
                # ⭐ The fused `.*` + `\z` tail (see
                # `_install_dotstar_eos_tail` for the shape proof).  The rest of
                # the subject is known to be irrelevant, so instead of stepping
                # it one byte at a time this thread TELEPORTS to `n`: the match
                # end is `n`, every SAVE on the exit chain writes `n`, and the
                # only thing that can stop it is a `\n` under a non-dotall `.`.
                #
                # ⚠ The chain walk below MUST mirror the recogniser exactly.  It
                # is safe to walk unguarded only because the recogniser PROVED at
                # compile time that `cur_pc + 3` starts a straight-line
                # `[SAVE]* ASSERT_EOS [SAVE]* MATCH`; the loop is bounded by that
                # MATCH, which is the `else` arm.
                var dotall_tail = self.prog[cur_pc + 1].a == 1
                if dotall_tail or not _tail_has_newline(subject, pos, n):
                    var tpc = cur_pc + 3
                    while True:
                        var tins = self.prog[tpc]
                        if tins.op == OP_SAVE:
                            if tins.a < nslots:
                                tl.stack_slots[sbase + tins.a] = n
                            tpc += 1
                        elif tins.op == OP_ASSERT:
                            # ASSERT_EOS, and `pos` is now `n`, so it holds.
                            tpc += 1
                        else:
                            break        # OP_MATCH
                    # Emit at the MATCH pc so `_run`'s step loop needs no change
                    # at all.  The `seen` stamp keeps leftmost-first priority:
                    # a higher-priority thread that already reached this MATCH
                    # this step wins, exactly as it would have at `n`.
                    if not tl.is_seen(tpc):
                        tl.mark_seen(tpc)
                        tl.pcs.append(tpc)
                        for k in range(nslots):
                            var v = tl.stack_slots[sbase + k]
                            tl.slots_flat.append(v)
                        tl.count += 1
                tl.stack_slots.resize(sbase, 0)
            else:
                # Consuming (CHAR / CLASS / ANY) or MATCH.
                tl.pcs.append(cur_pc)
                for k in range(nslots):
                    var v = tl.stack_slots[sbase + k]
                    tl.slots_flat.append(v)
                tl.count += 1
                tl.stack_slots.resize(sbase, 0)

    def _assert_holds(self, kind: Int, subject: Span[UInt8, _], pos: Int, n: Int) -> Bool:
        if kind == Int(ASSERT_BOS):
            return pos == 0
        if kind == Int(ASSERT_EOS):
            return pos == n
        if kind == Int(ASSERT_BOL):
            return pos == 0 or (pos > 0 and Int(subject[pos - 1]) == 10)
        if kind == Int(ASSERT_EOL):
            return pos == n or (pos < n and Int(subject[pos]) == 10)
        var before_word = pos > 0 and _is_word_byte(Int(subject[pos - 1]))
        var after_word = pos < n and _is_word_byte(Int(subject[pos]))
        if kind == Int(ASSERT_WORD_B):
            return before_word != after_word
        return before_word == after_word  # ASSERT_NOT_WORD_B


# ---------------------------------------------------------------------------
# The caller-owned execution scratch.
# ---------------------------------------------------------------------------
#
# ⭐ WHY THIS TYPE EXISTS.  Constructing the Pike VM's two thread lists per
# `_run` call, i.e. per row, costs ~5 allocations per row. This type hoists
# them to a caller-owned scratch, threaded through
# `find`/`find_from`/`is_match`/`find_all_in` as their `*_with` spellings.
#
# A columnar kernel builds ONE of these per column and hands it to every row.
# The lists then grow to the program's steady state on row 0 and are reused —
# `reset()` is a `clear()` (capacity retained) plus a generation bump, never a
# free.  For a 40-instruction program over an 81M-row column that is the
# difference between ~5 allocations per row and ~5 for the whole column.
#
# ⛔ IT CARRIES NO SEMANTICS.  Everything in it is overwritten or invalidated
# by `_run_with` before it is read: both lists are `reset()` on entry (which
# bumps `gen`, so every prior `seen` stamp is strictly below the live
# generation and reads as unseen), `stack_pc`/`stack_slots` are `clear()`ed by
# `_seed_thread`/`_add_thread_from` before use, and `match_slots` is refilled
# with -1.  A scratch may therefore be reused across rows, across SUBJECTS, and
# across PROGRAMS — a program of a different length is detected by
# `len(seen_gen) != prog_len` and the lists are rebuilt.
#
# THE FALSIFIER for all of that is a differential one, not an inspection:
# a test runs a whole column through a single scratch and asserts every row
# equals the one-shot (fresh-scratch) answer for that row alone.


struct RegexScratch(Movable):
    """Reusable Pike-VM execution scratch — see the note above.

    Hold one per column (or per thread) and pass it to `*_with`.  Construction
    is free: the lists are empty and are sized on first use against the
    program's instruction count.
    """

    var clist: _ThreadList
    var nlist: _ThreadList
    var match_slots: List[Int]
    # The BitState engine's bitmap / job stack / capture vector -- the capture
    # calls' fast path (`find_from_with_engine`).  Same contract as the rest of
    # this struct: no state survives a search (see `BitStateScratch`).
    var bits: BitStateScratch

    def __init__(out self):
        self.clist = _ThreadList(0)
        self.nlist = _ThreadList(0)
        self.match_slots = List[Int]()
        self.bits = BitStateScratch()


# ---------------------------------------------------------------------------
# Thread list + a per-step "seen pc" set.
# ---------------------------------------------------------------------------

struct _ThreadList(Movable):
    """The Pike VM's per-step thread list, plus the epsilon-closure scratch.

    ⭐ ALLOCATION-FREE STEPPING.  A naive Pike VM is dominated by the
    allocator, not by NFA stepping (profiled at >80% allocator family on a
    URL-rewriting pattern, at high IPC with negligible branch and cache misses —
    i.e. pure instruction count, not stalls). Three shapes produce nearly all
    of it, and all three are avoided here:

    1. A per-thread-per-byte `slots_for()` returning a FRESH `List[Int]`
    purely to read `nslots` integers. Instead `_run` indexes `slots_flat`
    directly.
    2. Allocating `stack_pc` + `stack_slots: List[List[Int]]` on EVERY
    `_add_thread` call (once per seed and once per surviving thread per
    byte), plus a further `List[Int]` per SPLIT and per SAVE inside the walk.
    Instead the stacks live HERE and are reused, and the slot stack is FLAT
    (`nslots` ints per entry) so an epsilon step is an append, not an
    allocation.
    3. Writing `False` over the whole `seen` array once per byte position.
    Instead it is a GENERATION STAMP: `reset()` is `gen += 1`.

    The two lists themselves live in the caller-owned `RegexScratch`, and
    `_run_with` re-arms it instead of constructing it, so a columnar kernel
    pays those allocations ONCE PER COLUMN, not once per row. The remaining
    per-batch cost in this family is `RegexProgram.compile`.
    """
    var pcs: List[Int]
    var slots_flat: List[Int]   # count * nslots, row-major
    var seen_gen: List[Int]     # one generation stamp per program pc
    var gen: Int                # current generation; `seen(pc)` iff stamp == gen
    var count: Int
    # Epsilon-closure scratch, reused across every `_closure` call on this list.
    # INVARIANT, at the top of the closure loop:
    #     len(stack_slots) == len(stack_pc) * nslots
    # and entry i of `stack_pc` owns `stack_slots[i*nslots : (i+1)*nslots]`.
    var stack_pc: List[Int]
    var stack_slots: List[Int]

    def __init__(out self, prog_len: Int):
        self.pcs = List[Int]()
        self.slots_flat = List[Int]()
        self.seen_gen = List[Int](length=prog_len, fill=0)
        self.gen = 1
        self.count = 0
        self.stack_pc = List[Int]()
        self.stack_slots = List[Int]()

    def copy(self) -> Self:
        var t = Self(len(self.seen_gen))
        t.pcs = self.pcs.copy()
        t.slots_flat = self.slots_flat.copy()
        t.seen_gen = self.seen_gen.copy()
        t.gen = self.gen
        t.count = self.count
        return t^

    def reset(mut self):
        self.pcs.clear()
        self.slots_flat.clear()
        # ⭐ The generation stamp replaces an O(prog_len) memset per byte
        # position.  `gen` starts at 1 and the stamps at 0, so nothing is seen
        # before the first mark.
        self.gen += 1
        self.count = 0

    @always_inline
    def is_seen(self, pc: Int) -> Bool:
        return self.seen_gen[pc] == self.gen

    @always_inline
    def mark_seen(mut self, pc: Int):
        self.seen_gen[pc] = self.gen


# ---------------------------------------------------------------------------
# Match result.
# ---------------------------------------------------------------------------

struct RegexMatch(Movable, Copyable):
    """Result of a regex search over a byte string.

    `matched`: whether a match was found.
    `start`/`end`: byte offsets of the overall match (== slots[0]/slots[1]).
    `slots`: capture-slot array, length `(n_groups + 1) * 2`.  Group g's
             span is `[slots[2g], slots[2g+1])`; (-1, -1) if g didn't
             participate.  Empty if captures weren't requested.
    """
    var matched: Bool
    var start: Int
    var end: Int
    var slots: List[Int]

    def __init__(out self):
        self.matched = False
        self.start = -1
        self.end = -1
        self.slots = List[Int]()

    def copy(self) -> Self:
        var m = RegexMatch()
        m.matched = self.matched
        m.start = self.start
        m.end = self.end
        m.slots = self.slots.copy()
        return m^

    @always_inline
    def group_span(self, g: Int) -> Tuple[Int, Int]:
        """Byte span [start, end) of capture group g (0 = whole match).

        Returns (-1, -1) if the group did not participate or is missing.
        """
        var a = 2 * g
        var b = 2 * g + 1
        if a < 0 or b >= len(self.slots):
            return (-1, -1)
        return (self.slots[a], self.slots[b])
