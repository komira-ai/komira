# =============================================================================
# plan_wire_admit.mojo — THE STRUCTURAL REFUSALS, BEFORE THE PARSE.
# =============================================================================
#
# WHY THIS FILE EXISTS: a per-field refusal discipline says nothing about the
# STRUCTURE of the bytes. Without this file there is no recursion bound, no node
# budget, no size cap, and the version gate fires only AFTER the full parse.
#
# `plan_wire_codec.mojo`'s ledger is about SHAPES THE FORMAT CANNOT CARRY — a
# UDF pointer, an unmodelled tag. Every one of those refusals runs on a value
# that a successful parse produced. None of them can fire on a message that
# kills the process on the way in, and a language-agnostic format is BY
# DEFINITION parsed from bytes some other program produced.
#
# ================== ★ WHAT AN UNBOUNDED DECODE DOES ==========================
#
# Measured with no admit pass in front of the decoder, on linux-x86-64 under a
# test runner with an 8 MiB main-thread stack:
#
#   PLAN nesting, 150 levels    841 bytes   refused later, per-field. survives.
#   PLAN nesting, 160 levels    901 bytes   ★ SIGSEGV.
#   EXPR nesting, 160 levels    907 bytes   survives.
#   EXPR nesting, 200 levels  1,147 bytes   ★ SIGSEGV.
#   UNION with 200,000 children 400,010 b   ★ ACCEPTED. The whole tree was
#                                             materialised; only a per-field
#                                             check on the ROOT then objected.
#   format_version = 99 wrapped
#     around a 1,000-level nest  5,941 b    ★ SIGSEGV. The version gate is
#                                             downstream of the parse, so it
#                                             never ran.
#
# ⚠ NINE HUNDRED AND ONE BYTES. Not a gigabyte, not a fuzzing campaign — under
# a kilobyte of input, and the process is gone. It is a SIGSEGV, not an
# exception: `plan_from_bytes` is `raises`, so a caller writes
# `try: plan_from_bytes(b) except: reject` and reasonably believes it has
# handled hostile input. It has not. There is no stack left to raise onto.
#
# The two alternating frames in the crash dump are the mutual recursion between
# `PbDecoder.read_message` and the generated `WirePlan.decode` — one native
# stack frame per nesting level, and NOTHING counts them.
#
# ============ ★★ THE ONE-BYTE BYPASS, AND WHAT BOUNDS THE STACK ==============
#
# A prescan that is not the decoder's own traversal does not hold. A walk that
# descends into a LEN payload only if the payload parses COMPLETELY is defeated
# by ONE byte:
#
#   PLAN nesting, 200 levels, clean          1,141 B   PLAN_WIRE_TOO_DEEP ✓
#   PLAN nesting, 160 levels + ONE 0x07        902 B   ★ SIGSEGV
#   UNION, 200,000 children  + ONE 0x07    400,011 B   ★ ACCEPTED
#
# A single trailing `0x07` (field 0, wire type 7) at the end of the outermost
# `WirePlan` makes "parses completely" false. Such a walk skips the entire
# 320-record subtree, honestly reports apparent depth 1, counts ZERO nodes, and
# admits. `decode_proto` then recurses in FIELD ORDER and reaches the malformed
# byte only on the way back OUT — 320 frames past the point where it could have
# mattered.
#
# ⚠ THE DEFECT IS NOT THE PREDICATE. IT IS THE SHAPE. A gate that bounds a
# traversal that STOPS WHERE THE DECODER KEEPS GOING makes "the admit walk saw
# depth 1" a true statement about the wrong walk. Both structural budgets fall
# to the identical byte, because both are computed by that walk. Only the size
# cap survives, because it reads no bytes at all.
#
# ★ WHAT BOUNDS THE STACK: `komira_proto_codec`'s `PbDecoder` COUNTS ITS OWN
# RECURSION (`PB_MAX_DECODE_DEPTH`, `_sub_decoder`). The guarantee lives ON the
# recursion, not beside it, so nothing has to agree with it. The bound is not a
# THREADED PARAMETER through generated `decode` bodies: it is a FIELD on the
# decoder, set in the single function that constructs a nested decoder — the
# generated code is untouched and never learns the bound exists. Because it
# lives in the runtime every proto message shares, every socket-facing
# `decode_proto` call and every direct `PbDecoder` construction for an RPC
# response body gets the same bound, prescan or not.
#
# ★ AND THIS WALK PERFORMS THE DECODER'S TRAVERSAL. It descends into EVERY
# length-delimited record and abandons a subtree at the first field header that
# does not parse — which is what `PbDecoder` does, one native frame at a time.
# It is still worth having, for two reasons that are not the stack:
#   * it refuses EARLIER and BY A BETTER NAME (`PLAN_WIRE_TOO_DEEP` at the
#     envelope, not `ProtobufError.TOO_DEEP` from inside the parse), and
#   * it carries `PLAN_WIRE_MAX_NODES`, which is a property of what a PLAN is
#     and has no business in a protobuf runtime. The breadth attack — 200,000
#     siblings, three levels deep — is invisible to any depth bound anywhere.
#
# ================= ⚠ WHAT IS GUARANTEED, AND WHAT IS NOT =====================
#
# ★ A CRASH IS NOT A REFUSAL. Stating the boundary precisely, because the last
# version of this file stated one it did not have:
#
#   GUARANTEED — a NAMED `Error` a caller can catch, never a signal:
#     * ANY byte sequence handed to `plan_from_bytes`. Every structural failure
#       mode measured on this format — arbitrary nesting depth, arbitrary node
#       count, arbitrary size, truncation at any offset, single-byte corruption
#       at any offset, a trailing byte at any depth, a version this build does
#       not speak — refuses by name. The depth leg no longer rests on this
#       walk's judgement: `PbDecoder` refuses on its own count even if this
#       walk is defeated again.
#     * ANY byte sequence handed to `decode_proto` for ANY message in the repo,
#       for the STACK specifically. That bound is schema-independent.
#
#   ⚠ AND "GUARANTEED" MEANS A BOUND PLUS A CORPUS, NOT A PROOF. The stack leg
#   IS a bound — a counter on the recursion, true of every input. The rest is a
#   bound (size, depth, nodes) plus the classes this file's tests actually
#   drive. A failure mode nobody has thought of is not covered by a sentence
#   saying it is.
#
#   ⚠ NOT GUARANTEED, and deliberately named rather than implied:
#     * THAT EVERY LEGITIMATE PLAN IS ADMITTED. The walk over-counts (it has no
#       schema, so a `string` or a `bytes` costs a level and a node), so a plan
#       carrying a payload that itself reads as deep framing — a serialized
#       message stuffed into a `ScanParams` value, say — can be refused for
#       depth it does not have. The margin is measured by this package's tests
#       and it is not proved.
#     * MEMORY. `PB_MAX_DECODE_DEPTH` bounds the stack, not the heap. A 16 MiB
#       message of sibling records inside the node budget still allocates what
#       it declares. `PLAN_WIRE_MAX_BYTES` is the only thing standing between a
#       socket and that allocation, and a caller reading from a socket should
#       apply it AT the socket — which is why it is exported.
#     * `decode_json`. `komira_proto_codec`'s JSON backend is not bounded by this
#       file: `parse_json_value` nests on `{`/`[`, and `JsonDecoder.read_message`
#       constructs a sub-decoder of its own. `plan_from_bytes` does not use it.
#       Any JSON surface exposed to a foreign producer — a REST body, a
#       gRPC-JSON transcode — needs its own depth bound, the way `PbDecoder` has
#       one. Named here rather than implied, because "the format is bounded" is
#       what a reader will otherwise take away from this file.
#     * THE ENCODER. `plan_to_bytes` recurses over a `LogicalPlan` built in
#       this process. A plan deep enough to overflow it was constructed here,
#       not received.
#     * SEMANTIC nonsense. A message that is structurally sound and means
#       something absurd is the per-field ledger's job (`plan_wire_codec.mojo`),
#       and every refusal there is downstream of a successful parse — which is
#       correct, now that the parse is survivable.
#
# THAT ORDERING IS ALSO THE ANSWER TO THE VERSION COMPLAINT. Once there is a
# pass that precedes the parse, `format_version` is read in it — from the
# envelope's TOP-LEVEL field stream, without descending into anything. A
# version-2 reader now spends ~10 bytes deciding it cannot read a version-99
# message, instead of parsing the whole tree first.
#
# ============ ⚠ THE OVER-APPROXIMATION, STATED BECAUSE IT IS REAL ============
#
# On the raw protobuf wire a length-delimited record is a nested MESSAGE, a
# `string`, or a `bytes` — and the three are INDISTINGUISHABLE without the
# schema. This walk has no schema (deriving one would duplicate the generated
# code, which is the thing most likely to drift from it). It therefore descends
# into EVERY LEN record, strings included, and each one costs a level and a
# node while the walk is inside it.
#
#   SOUNDNESS  apparent depth >= decoder depth, POINTWISE, and this time the
#              claim is structural rather than statistical. The decoder
#              descends on a LEN field iff the schema calls it a message; this
#              walk descends on EVERY LEN field. A superset of descents, taken
#              in the same order, abandoned on the same conditions. There is no
#              input on which the decoder goes deeper than this walk, because
#              there is no descent the decoder makes that this walk skips.
#
#   THE COST   a legitimate plan reads DEEPER than it is — now by one level per
#              string on its deepest path, where before it was by one level per
#              string that happened to parse. That is a real risk and it is
#              MEASURED, not assumed: `test_plan_wire_hostile_bytes.mojo`'s
#              `test_the_margin_on_real_plans_is_stated` (4x headroom over the
#              plans that file builds) prints the apparent depth of real plans.
#              The numbers live in that log, not in this comment, because a
#              number in a comment is not a measurement.
#
# ⚠ THE OVER-COUNT IS +1 PER STRING AND IT CANNOT COMPOUND. A string's bytes
# are walked as a field stream exactly until they stop parsing; a string that
# parses as a field stream for a while can push a few extra levels, but each of
# those costs a node, and `PLAN_WIRE_MAX_NODES` bounds the total. Text stops
# almost immediately in practice — `"orders"` begins `0x6f`, field 13 wire type
# 7, and wire type 7 does not exist.
#
# ============================== THE COST MODEL ===============================
#
# Every byte is read as a field header at most once, at the single nesting
# level that owns it: descending moves INTO a payload, abandoning or exhausting
# a record resumes AFTER it, and neither re-reads what the other read. So the
# walk is O(n) — strictly cheaper than validating each payload as a field
# stream BEFORE walking it, which is O(n · depth). The number of descents is
# separately capped by `PLAN_WIRE_MAX_NODES`.
#
# Encapsulation: pure index arithmetic over a borrowed `List[UInt8]`. No
# UnsafePointer, no Span stored anywhere, nothing recursive.
# =============================================================================


# =============================================================================
# THE THREE BUDGETS
# =============================================================================
#
# ⚠ THESE ARE NOT POLICY PREFERENCES. `PLAN_WIRE_MAX_DEPTH` is DERIVED from the
# measurement at the top of this file — the decoder physically cannot survive
# past ~320 records, so the only question was how much margin to keep. The other
# two are engineering judgements about what a plan plausibly is, and each says
# what it was derived against so a future plan that violates it can argue.

comptime PLAN_WIRE_MAX_DEPTH: Int = 64
"""Maximum nesting of length-delimited records, counting the envelope as 1.

WHY 64. The measured crash is at 160 PLAN levels / 200 EXPR levels, and one
plan level is TWO of these (`WirePlan` -> `WireFilterNode` -> `WirePlan`), so
the stack dies somewhere past 320 of the units this constant counts. 64 keeps a
5x margin.

⚠ THE MARGIN IS NOT DECORATION, because the crash point is a property of the
STACK, not of the format. 320 was measured on an 8 MiB main thread. A reader
that decodes a plan on a pooled worker thread may have 512 KiB, and would crash
at a small fraction of that. This bound is what makes the failure a REFUSAL on
every stack size big enough to run the codec at all; it is not tuned to one.

⚠ AND IT IS A CEILING, NOT A TARGET. A plan nesting 64 message levels deep is
32 plan nodes or a 32-term left-deep boolean chain. `plan_display` renders
those; nothing in the SQL corpus comes close. The number that matters is in the
test log (`APPARENT DEPTH of real plans`), which is what stops this constant
from drifting into a false refusal unnoticed.

★ `PB_MAX_DECODE_DEPTH` IS THE SAME NUMBER IN THE SAME UNIT, AND THAT IS NOT A
COINCIDENCE. That one is the decoder's count of its own recursion; this one is
this walk's count of the records enclosing a position. They must be equal, not
merely close: this walk descends into a SUPERSET of the records the decoder
recurses into, so its depth is >= the decoder's pointwise, so at equal caps a
message this gate ADMITS can never be refused by the decoder. Raise this one
above that one and plans would start failing with `ProtobufError.TOO_DEEP`
from inside the parse; lower it and the earlier, better-named refusal fires
first, which is only a cosmetic loss. Equal is the setting where they cannot
fight."""

comptime PLAN_WIRE_MAX_NODES: Int = 65536
"""Maximum number of length-delimited records descended into.

★ THE BREADTH ATTACK A DEPTH BOUND CANNOT SEE, AND THE ONLY BUDGET HERE THAT
`PB_MAX_DECODE_DEPTH` DOES NOT SUBSUME. The measured 200,000-child
`WireUnionNode` is THREE levels deep. Every depth bound in the world admits it —
the decoder's own included — and the decoder materialised all 200,000 before a
per-field check on the root happened to object, a refusal that had nothing to do
with the size and would not have fired had the root been well-formed. This is
the whole reason the walk survives now that the stack is bounded at the
recursion: a node count is a statement about what a PLAN is, and a protobuf
runtime has no business holding an opinion about that.

⚠ THIS COUNTS EVERY LENGTH-DELIMITED RECORD, STRINGS INCLUDED. The walk
descends into all of them (it has no schema, and the one-byte bypass shows that
guessing is unsafe), so a `string` field costs a node exactly like a nested
message does. Roughly a 2x over-count against the true node total on real plans.
That is deliberate over-approximation in the sound direction and the headroom
absorbs it — but if this constant is ever tuned, tune it against real SQL
shapes put through the frontend, not against a hand-built plan.

WHY 65536: this format carries WHOLE PLANS, not an expression list. A scan over
a 4,000-column table spends a `WireField` per column plus a `WireExpr` per
projected column plus a name string for each, so a five-figure node count is
ordinary here.
"""

comptime PLAN_WIRE_MAX_BYTES: Int = 16777216
"""Maximum encoded size — 16 MiB. Refused WITHOUT READING: this is the only
budget whose check costs O(1), and it is checked first for exactly that reason.

SPELLED AS A LITERAL (`16 * 1024 * 1024`), so a tool that reads constants as a
decimal right-hand side sees all three budgets the same way.

A plan is an ABSTRACT SYNTAX TREE, not data. 16 MiB is roughly three orders of
magnitude above the largest plan the SQL frontend produces. A caller that
receives bytes over a socket
should apply this cap at the socket, before allocating; it is exported so that
is possible.
"""

comptime PLAN_WIRE_TOO_DEEP: String = "PLAN_WIRE_TOO_DEEP"
comptime PLAN_WIRE_TOO_MANY_NODES: String = "PLAN_WIRE_TOO_MANY_NODES"
comptime PLAN_WIRE_TOO_LARGE: String = "PLAN_WIRE_TOO_LARGE"

comptime PLAN_WIRE_VERSION_MISMATCH: String = "PLAN_WIRE_VERSION_MISMATCH"
"""⚠ THIS TOKEN LIVES HERE AND NOT IN THE CODEC, and that placement is the point.

Raised on the DECODED `env.format_version`, it would fire only after
`decode_proto` had built the entire tree. Reading the version is an
ENVELOPE-FRAMING question, not a plan question, so it belongs in the pass that
runs before the plan exists. `PLAN_WIRE_FORMAT_VERSION`
— the number, and the rules for bumping it — stays in the codec, and is passed
in: this file must not know what version anybody speaks, only where the field
is."""

comptime PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED: String = (
    "PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED"
)
"""★ THE REFUSAL THAT MAKES THE VERSION BUMP WORTH ANYTHING.

`WirePlanEnvelope.write_target` (field 3) requires a reader that knows what
field 3 IS. A reader that does not know it does not error — proto3 forward
compatibility means it SKIPS the field, runs the query, returns rows, writes no
file, and raises nothing. That is
`PLAN_ENDPOINT_PRODUCER_SQL_WRITE_STATEMENT_DROPPED(36)` reproduced one layer
down, by the mechanism that was supposed to make 36 unnecessary.

Bumping the WRITER to `format_version = 5` on write-carrying envelopes is what
lets an old reader refuse them. But a writer bump is a claim about bytes WE
wrote, and this format's whole contract is that the bytes come from somewhere
else. So the READER enforces the other half:

    field 3 present  AND  declared version < 5   ->  REFUSED, by this name.

That converts "a conformant producer declares 5" from a convention a frontend
author may forget into a rule the wire enforces on the first message. Without
it, a Python or TypeScript frontend that sets `write_target` and leaves
`format_version = 4` produces bytes that THIS build executes correctly and that
every older reader executes WRONG — and the difference is invisible from either
side.

⚠ IT IS NOT SYMMETRIC, DELIBERATELY. An OVERSTATED version (5 declared, no
write target) is ACCEPTED. The version is a MINIMUM READER CAPABILITY, so
declaring a floor higher than you need is conservative: it can only cause an
older reader to refuse bytes it would in fact have handled, which is a lost
capability and never a wrong answer. Understating is the one direction that
produces silence."""


# =============================================================================
# WHICH VERSIONS THIS READER SPEAKS — a SET, not a number
# =============================================================================


@fieldwise_init
struct PlanWireVersionSet(Copyable, Movable, Deinitable):
    """The set of `format_version` values a reader will admit.

    ★ WHY A TYPE AND NOT A `UInt32`. A gate over a single version takes a bare
    `expected_version: UInt32` and compares with `!=`. Widening that to a set
    the obvious way — pass a bitmask `UInt32` — would leave every call site
    type-identical to the single-version one, so a caller that kept passing
    `PLAN_WIRE_FORMAT_VERSION` (the number 4) would compile, and mask 4 is bit
    2, i.e. the set {2}: a reader that accepts NO version it speaks and accepts
    one this build refuses. A distinct type makes that call a compile
    error instead of a silent inversion of the gate.

    ⚠ SET MEMBERSHIP, NOT `>=`. The version is a MINIMUM READER CAPABILITY, and
    an ordering would say something stronger and false — that every future
    version is readable by any reader that speaks a lower one. The whole reason
    this field exists (see `PLAN_WIRE_FORMAT_VERSION`'s docstring) is the CHANGE
    A MEANING case, and a version that changed a meaning must be able to LEAVE
    the set. `{4, 5}` today, and 2 and 3 are outside it.

    Versions must be < 32 (one bit each). That is checked rather than assumed:
    at 32 the shift is undefined and the set would silently gain or lose a
    member, which is the failure this type exists to prevent.
    """

    var _mask: UInt32

    @staticmethod
    def only(v: UInt32) raises -> Self:
        """The single-version set — a reader PINNED at `v`.

        This is what makes "an old reader must refuse these bytes" a testable
        claim rather than an argument: a test constructs `only(2)` and drives
        the CURRENT decoder through it."""
        return Self(Self._bit(v))

    def plus(self, v: UInt32) raises -> Self:
        return Self(self._mask | Self._bit(v))

    @staticmethod
    def _bit(v: UInt32) raises -> UInt32:
        if v >= 32:
            raise Error(
                "PLAN_WIRE_MALFORMED: format_version "
                + String(Int(v))
                + " cannot be a member of a PlanWireVersionSet — the set is a"
                " 32-bit mask and the shift is undefined at 32. A version this"
                " large is a format generation nobody has designed; widen the"
                " representation deliberately rather than shifting past the end."
            )
        return UInt32(1) << v

    def contains(self, v: UInt32) -> Bool:
        if v >= 32:
            return False
        return (self._mask & (UInt32(1) << v)) != 0

    def render(self) -> String:
        """`{4, 5}` — for the refusal message. A reader that says only "wrong
        version" tells a frontend author nothing about what to write."""
        var out = String("{")
        var first = True
        for v in range(32):
            if (self._mask & (UInt32(1) << UInt32(v))) != 0:
                if not first:
                    out += ", "
                out += String(v)
                first = False
        return out + String("}")


# =============================================================================
# A NON-RAISING WIRE SCANNER
# =============================================================================
#
# ⚠ WHY THIS DOES NOT REUSE `komira_protobuf`'s `pb_read_tag` /
# `pb_read_varint`. Those RAISE on a malformed read, and the walk below reads a
# field header inside EVERY length-delimited record in the message — which is a
# read whose answer is routinely "this is not a field" (every string in the
# plan). Building an `Error` per string is the wrong shape, and a walk written
# as try/except reads as if failure were exceptional when it is the common
# case. These return a validity flag instead.
#
# ⚠ AND THE FAILURE CONDITIONS MUST MATCH THEIRS EXACTLY, because that
# correspondence is what makes this walk's traversal the decoder's. Each arm of
# `_read_field` below fails on precisely what the `pb_*` reader for that arm
# raises on: field number 0 and the 10-byte varint cap (`pb_read_tag` /
# `pb_read_varint`), wire types 3/4/6/7 (`pb_skip_field`), and a length that
# runs past the enclosing record (`pb_read_len_field`). A condition this file
# checks that they do not is harmless (this walk merely stops sooner than the
# decoder inside a subtree it over-descended into); a condition THEY check that
# this file does not is harmless for the same reason; a condition this file
# treats as fatal at a level where the decoder keeps reading is the one-byte
# bypass described at the top of this file, and there is no such condition — a
# stop inside a descended record is not fatal here at all.


@fieldwise_init
struct _Read(Copyable, Movable, ImplicitlyCopyable):
    """A varint read: whether it parsed, its value, and the position after."""

    var ok: Bool
    var value: UInt64
    var next: Int


@fieldwise_init
struct _Field(Copyable, Movable, ImplicitlyCopyable):
    """One decoded field header. `payload_*` spans the field's VALUE — the
    length-delimited payload for wire type 2, and the varint / fixed bytes
    otherwise; `next` is where the following field begins."""

    var ok: Bool
    var field_no: Int
    var wire: Int
    var payload_start: Int
    var payload_end: Int
    var next: Int


def _bad_field() -> _Field:
    return _Field(False, 0, -1, 0, 0, 0)


def _read_varint(bytes: List[UInt8], pos: Int, end: Int) -> _Read:
    """base-128, low group first. Bounded by `end` and by the 10-byte maximum
    of a 64-bit varint — an 11th continuation byte is malformed, not a value
    to keep shifting into."""
    var p = pos
    var shift = 0
    var acc: UInt64 = 0
    var count = 0
    while p < end:
        var b = bytes[p]
        acc |= UInt64(b & 0x7F) << UInt64(shift)
        p += 1
        count += 1
        if (b & 0x80) == 0:
            return _Read(True, acc, p)
        if count == 10:
            return _Read(False, 0, p)
        shift += 7
    return _Read(False, 0, p)


def _read_field(bytes: List[UInt8], pos: Int, end: Int) -> _Field:
    """Decode one field header and locate the field's payload.

    Every arm is bounded by `end`, so a caller can never be handed a span that
    leaves its parent — which is what makes the walk below safe to run on
    bytes chosen by an adversary."""
    var t = _read_varint(bytes, pos, end)
    if not t.ok:
        return _bad_field()
    var wire = Int(t.value & 0x7)
    var field_no = Int(t.value >> 3)
    if field_no == 0:
        # Field number 0 is illegal in every version of protobuf, and
        # `pb_read_tag` raises on it — which is what lets the walk treat this
        # as "the record ended here" and know the decoder ends there too. (It
        # is NOT the walk's most productive rejection; that is the wire-type
        # test below. Field 0 needs a tag byte in 0x00-0x07, i.e. a control
        # character, whereas ordinary text lands on wire types 6 and 7, which
        # do not exist. `"orders"` begins 0x6f = field 13, wire 7.)
        return _bad_field()
    var p = t.next

    if wire == 0:
        var v = _read_varint(bytes, p, end)
        if not v.ok:
            return _bad_field()
        return _Field(True, field_no, 0, p, p, v.next)
    if wire == 1:
        if p + 8 > end:
            return _bad_field()
        return _Field(True, field_no, 1, p, p + 8, p + 8)
    if wire == 5:
        if p + 4 > end:
            return _bad_field()
        return _Field(True, field_no, 5, p, p + 4, p + 4)
    if wire == 2:
        var l = _read_varint(bytes, p, end)
        if not l.ok:
            return _bad_field()
        var s = l.next
        # ⚠ COMPARE IN UInt64, WIDEN NEVER. `l.value` is attacker-chosen and
        # reaches 2^64-1; `s + Int(l.value)` would wrap to a small positive
        # offset and the overrun check would pass. Asking whether the declared
        # length exceeds the bytes REMAINING cannot overflow.
        if l.value > UInt64(end - s):
            return _bad_field()
        var e = s + Int(l.value)
        return _Field(True, field_no, 2, s, e, e)

    # Wire types 3 and 4 are the removed group encoding; 6 and 7 have never
    # existed. proto3 emits none of them, so any of the four means these bytes
    # are not a message this format can contain.
    return _bad_field()


# =============================================================================
# THE WALK
# =============================================================================


def _walk(bytes: List[UInt8], mut max_depth: Int) raises:
    """Iterative depth-first walk of the message framing.

    ⚠ ITERATIVE, DELIBERATELY. `ends` / `resumes` hold the end offset and the
    resume position of every open record; descending pushes, leaving a record
    pops. A recursive version of this function would be killed by the same
    input it exists to refuse, and would do it while claiming to be the fix.

    ★ IT DESCENDS INTO EVERY LENGTH-DELIMITED RECORD, and abandons a subtree at
    the first field header that does not parse. That is not a heuristic — it is
    the decoder's own control flow, written iteratively:

        DESCEND   `PbDecoder.read_message` recurses on a LEN field whenever the
                  SCHEMA says the field is a message. This walk has no schema,
                  so it descends on EVERY LEN field — a superset, always.
        ABANDON   the decoder stops enumerating a message at the first tag its
                  reader rejects (`pb_read_tag` on field 0 or a bad varint,
                  `pb_skip_field` on wire types 3/4/6/7, `pb_read_len_field` on
                  an overrunning length). This walk stops on exactly those, and
                  a stop INSIDE a descended payload is not an error — it is the
                  answer "that record was a string, not a message".

    Those two properties together give `apparent_depth(p) >= decoder_depth(p)`
    at every position, which is the only direction that matters.

    `max_depth` is an out-parameter rather than a return value so a caller that
    catches the refusal still learns HOW deep the walk got — which is what
    makes the apparent-depth measurement usable on inputs that are refused."""
    var ends = List[Int]()
    var resumes = List[Int]()
    var pos = 0
    var end = len(bytes)
    var depth = 1  # the envelope message itself
    var nodes = 0
    max_depth = 1

    while True:
        if pos >= end:
            if len(ends) == 0:
                return
            end = ends.pop()
            pos = resumes.pop()
            depth -= 1
            continue

        var f = _read_field(bytes, pos, end)
        if not f.ok:
            if len(ends) == 0:
                # ⚠ THE TOP LEVEL IS THE ONLY PLACE THIS IS AN ERROR. These
                # bytes are not a field stream at all, so there is no envelope.
                # (`plan_wire_admit` reaches `plan_wire_envelope_prescan` first, which
                # raises the same way — this is the raise the OTHER entry point,
                # `plan_wire_apparent_depth`, needs.)
                raise Error(
                    "PLAN_WIRE_MALFORMED: the field stream does not parse at"
                    " byte offset "
                    + String(pos)
                    + ". These bytes are not a"
                    " `komira.plan.v1.WirePlanEnvelope`."
                )
            # ★★ NOT AN ERROR, AND THIS IS THE WHOLE FIX. A record that stops
            # parsing part-way through is a STRING (or a `bytes`, or a packed
            # scalar field) that happened to begin with a plausible tag — the
            # common case, not the exceptional one. Abandon the subtree and
            # resume in the parent at the position AFTER this record.
            #
            # Requiring a payload to parse COMPLETELY before descending is the
            # wrong shape: one appended `0x07` makes that false for the
            # outermost `WirePlan`, so such a walk skips a 320-record nest
            # entirely, reports depth 1, and admits 902 bytes that then
            # SIGSEGV the decoder. The decoder does not pre-check; it descends
            # and finds out. So does this.
            end = ends.pop()
            pos = resumes.pop()
            depth -= 1
            continue

        if f.wire != 2:
            pos = f.next
            continue

        nodes += 1
        if nodes > PLAN_WIRE_MAX_NODES:
            raise Error(
                PLAN_WIRE_TOO_MANY_NODES
                + ": this message frames more than "
                + String(PLAN_WIRE_MAX_NODES)
                + " nested records. A plan is an abstract syntax tree; a node"
                " count this large is a denial-of-service payload, not a"
                " query. ⚠ Note this bound is INDEPENDENT of depth — the"
                " message that motivated it is three levels deep."
            )
        depth += 1
        if depth > max_depth:
            max_depth = depth
        if depth > PLAN_WIRE_MAX_DEPTH:
            raise Error(
                PLAN_WIRE_TOO_DEEP
                + ": this message nests more than "
                + String(PLAN_WIRE_MAX_DEPTH)
                + " levels of length-delimited records. The decoder recurses"
                " once per level and would exhaust the stack — measured, that"
                " is a SIGSEGV and not an exception, so this refusal is the"
                " only form the failure can take that a caller is able to"
                " catch."
            )
        ends.append(end)
        resumes.append(f.next)
        end = f.payload_end
        pos = f.payload_start


def plan_wire_apparent_depth(bytes: List[UInt8]) -> Int:
    """How deep this walk got before it finished or gave up.

    ⚠ APPARENT, not real — see the over-approximation note at the top of this
    file. Exported so a test can MEASURE the margin between an ordinary plan
    and `PLAN_WIRE_MAX_DEPTH` rather than assert that somebody once believed it
    was comfortable. On a refused message this is how deep the walk reached,
    which is the useful answer for both callers that exist."""
    var d = 0
    try:
        _walk(bytes, d)
    except:
        pass
    return d


comptime PLAN_WIRE_WRITE_TARGET_MIN_VERSION: UInt32 = 5
"""The `format_version` floor a `write_target`-carrying envelope must declare.

⚠ IT LIVES HERE, NOT IN THE CODEC, FOR THE SAME REASON THE VERSION TOKEN DOES.
The prescan is the pass that KNOWS field 3 is present — it is the only pass that
reads the top-level field stream without parsing the tree — so the floor it
enforces has to be readable here. What stays in the codec is which versions this
BUILD speaks; what lives here is which version a given SHAPE requires, which is
a property of the format and not of any build."""


def plan_wire_admit(bytes: List[UInt8], accepted: PlanWireVersionSet) raises:
    """THE GATE. Refuse hostile or merely-broken bytes BEFORE they are parsed.

    THE ORDER IS THE POINT, and each step is cheaper than the one it protects:

      1. SIZE     O(1). Refuses without reading a byte.
      2. VERSION  O(top-level fields) — about ten bytes. ★ A version-2 reader
                  must not do the work of parsing a version-99 message before
                  deciding it cannot read it. Measured, a version check placed
                  after `decode_proto` does not merely waste work: a
                  version-99 message wrapped around a deep nest kills the
                  process first, so such a gate is not just late, it is
                  unreachable.
      2b. CAPABILITY FLOOR — a `write_target` (field 3) present under a version
                  that predates it. See
                  `PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED`: this is the one
                  refusal in this file that is not about hostile bytes but about
                  a SILENCE, and it costs the same top-level scan step 2 already
                  pays for.
      3. STRUCTURE O(n). Depth and node budgets, enforced as the walk descends.

    Every refusal carries a `PLAN_WIRE_*` token, the same discipline the
    per-field ledger already follows — a caller can tell "too big" from "too
    deep" from "not for this build" without reading prose."""
    var n = len(bytes)
    if n > PLAN_WIRE_MAX_BYTES:
        raise Error(
            PLAN_WIRE_TOO_LARGE
            + ": "
            + String(n)
            + " bytes exceeds the "
            + String(PLAN_WIRE_MAX_BYTES)
            + "-byte cap. Refused without parsing. A plan is an abstract"
            " syntax tree, not data — if this is a legitimate plan, the cap is"
            " wrong and should be changed deliberately, in"
            " `plan_wire_admit.mojo`, with the plan that motivated it named."
        )

    var scan = plan_wire_envelope_prescan(bytes)
    if not accepted.contains(scan.version):
        raise Error(
            PLAN_WIRE_VERSION_MISMATCH
            + ": these bytes declare format_version="
            + String(Int(scan.version))
            + "; this build speaks "
            + accepted.render()
            + ". Refused BEFORE the plan was parsed — the whole tree is still"
            " unread, which is the point: a reader must not do the work of"
            " parsing a message it has already decided it cannot execute."
            " ⚠ THE CHECK IS SET MEMBERSHIP, NOT `>=`: a version is a MINIMUM"
            " READER CAPABILITY, and one whose meaning changed must be able to"
            " leave the set."
        )

    if scan.has_write_target and scan.version < PLAN_WIRE_WRITE_TARGET_MIN_VERSION:
        raise Error(
            PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED
            + ": these bytes carry `WirePlanEnvelope.write_target` (field 3)"
            " and declare format_version="
            + String(Int(scan.version))
            + ", but a write-carrying envelope MUST declare at least "
            + String(Int(PLAN_WIRE_WRITE_TARGET_MIN_VERSION))
            + ". ⚠ THIS BUILD COULD HAVE EXECUTED THEM CORRECTLY AND REFUSES"
            " ANYWAY, on purpose. The version is what makes a reader that does"
            " NOT know field 3 refuse instead of skipping it — and a reader"
            " that skips it runs the query, returns rows, writes NO FILE and"
            " raises nothing. Understating the version hands those bytes to"
            " every such reader. Set format_version="
            + String(Int(PLAN_WIRE_WRITE_TARGET_MIN_VERSION))
            + " on the envelope."
        )

    var depth = 0
    _walk(bytes, depth)


@fieldwise_init
struct PlanWireEnvelopePrescan(Copyable, Movable, Deinitable):
    """What the top-level field stream says, without parsing the tree.

    Two facts, ONE scan. They are returned together rather than by two
    functions because they are read together and a caller that took the version
    and forgot the write-target flag would be a gate with the hole this type
    exists to close."""

    var version: UInt32
    var has_write_target: Bool


def plan_wire_envelope_prescan(bytes: List[UInt8]) raises -> PlanWireEnvelopePrescan:
    """Read `WirePlanEnvelope`'s top-level field stream, descending into nothing.

    `format_version` is field 1 (varint); `write_target` is field 3
    (length-delimited). Neither read follows a pointer into the tree, which is
    what makes this affordable before the size and structure gates have run.

    ⚠ LAST ONE WINS for the version, matching proto3 and matching what
    `decode_proto` does when it assigns the field on each occurrence. A scanner
    that took the FIRST occurrence would disagree with the decoder about what
    version a message declares, which is a worse failure than having no scanner:
    the gate would admit bytes the parser then reads as something else.

    ⚠ PRESENCE, NOT VALUE, for the write target — and PRESENCE OF THE FIELD, not
    of a non-empty one. proto3 lets a producer emit a zero-length submessage, and
    that still means "this envelope is a write". The decoder is what refuses an
    empty path; this pass only has to agree with the decoder about whether field
    3 IS THERE, because that agreement is what the capability floor rests on.

    An absent `format_version` is 0, which is not a version any build speaks, so
    a zero-byte or plan-less message is refused by name at the caller."""
    var p = 0
    var e = len(bytes)
    var version: UInt32 = 0
    var has_write_target = False
    while p < e:
        var f = _read_field(bytes, p, e)
        if not f.ok:
            raise Error(
                "PLAN_WIRE_MALFORMED: the envelope's top-level field stream"
                " does not parse at byte offset "
                + String(p)
                + ". These bytes are not a"
                " `komira.plan.v1.WirePlanEnvelope`."
            )
        if f.field_no == 1 and f.wire == 0:
            var v = _read_varint(bytes, f.payload_start, e)
            if v.ok:
                version = UInt32(v.value & 0xFFFFFFFF)
        elif f.field_no == 3 and f.wire == 2:
            has_write_target = True
        p = f.next
    return PlanWireEnvelopePrescan(version, has_write_target)
