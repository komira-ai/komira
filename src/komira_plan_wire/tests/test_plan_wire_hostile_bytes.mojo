# =============================================================================
# test_plan_wire_hostile_bytes.mojo — BYTES THIS CODEC DID NOT WRITE.
# =============================================================================
#
# THE PROPERTY THIS FILE EXISTS TO HOLD: refusal discipline that is excellent
# per-field is worthless if it is ABSENT STRUCTURALLY — no recursion bound, no
# node budget, no size cap, and a version gate that fires AFTER the full parse.
#
# A language-agnostic format is BY DEFINITION parsed from bytes some other
# program produced. Every other test in this family hands the decoder bytes the
# ENCODER wrote — so every one of them is a test of a well-formed message. The
# per-field refusals are all downstream of a parse that already succeeded; none
# of them can fire on a message that kills the process on the way in.
#
# ⚠ WHAT AN UNGUARDED DECODER DOES, so nobody has to re-derive it (linux-x86-64,
# under a test runner's default stack):
#
#   INPUT                            BYTES   UNGUARDED BEHAVIOUR
#   PLAN nesting, 150 levels           841   refused later, per-field. survives.
#   PLAN nesting, 160 levels           901   ★ SIGSEGV
#   EXPR nesting, 160 levels           907   survives
#   EXPR nesting, 200 levels         1,147   ★ SIGSEGV
#   UNION with 200,000 children    400,010   ★ ACCEPTED — whole tree built
#   version=99 over a 1,000 nest     5,941   ★ SIGSEGV (the gate never runs)
#
# ⚠ NINE HUNDRED AND ONE BYTES. And it is a SIGSEGV, not an exception:
# `plan_from_bytes` is `raises`, so a caller writes
# `try: plan_from_bytes(b) except: reject` and reasonably believes it has
# handled hostile input. It has not — there is no stack left to raise onto.
#
# The last row is the version complaint made concrete. A gate behind the parse
# is not merely LATE; it is UNREACHABLE, because the parse it sits behind is
# the thing that dies. Guarded, that same input returns
# `PLAN_WIRE_VERSION_MISMATCH` — and the fact that it is that token and not
# `PLAN_WIRE_TOO_DEEP` is what proves the ordering, which is why the leg below
# is written the way it is.
#
# ★★ AND A PRESCAN ALONE IS BEATEN BY ONE BYTE:
#
#   PLAN nesting, 160 levels + ONE 0x07     902   ★ SIGSEGV
#   UNION, 200,000 children  + ONE 0x07 400,011   ★ ACCEPTED
#
# A trailing byte no protobuf tag can be, appended to the outermost `WirePlan`,
# makes a prescan that declines to descend into an unparseable payload report
# depth 1 about a 320-record nest. It bounds a traversal that STOPS WHERE THE
# DECODER KEEPS GOING. That is why the `TRAILING BYTE` section below exists,
# and why the `DECODER BOUND` section after it reaches PAST `plan_from_bytes`
# — the walk is not where the guarantee lives.
#
# ============================== WHAT IS ASSERTED =============================
#
#   DEPTH    A nest deeper than the bound is `PLAN_WIRE_TOO_DEEP`, BY NAME,
#            and the process survives to say so.
#   NODES    More framed records than the budget is `PLAN_WIRE_TOO_MANY_NODES`.
#   SIZE     More bytes than the cap is `PLAN_WIRE_TOO_LARGE`, refused without
#            reading them.
#   VERSION  A version this build does not speak is refused BEFORE the tree is
#            parsed — asserted by giving the message a body that would itself
#            be refused for a DIFFERENT reason, and requiring the VERSION token.
#            A gate that fires after the parse names the deeper failure.
#   LEGIT    Every plan the rest of the suite round-trips still round-trips.
#            A bound that refuses real plans is worse than no bound.
#   IDENTITY Two legal encodings of ONE plan decode to the same plan — the
#            "no canonical form" concern, answered by writing the property
#            down rather than by inventing a canonical form.
#   ★ BYPASS  A stopper byte — trailing, leading, or buried 40 levels down —
#            cannot hide a nest or a node count from the gate. These are the
#            legs that are RED against a prescan that stops descending.
#   ★ DECODER `decode_proto` refuses a deep message WITH NO GATE IN FRONT OF IT.
#            Every other leg here goes through `plan_from_bytes` and is
#            satisfied by the walk alone; this one is the only one that can tell
#            `PbDecoder`'s recursion bound from a comment, and it is the bound
#            that keeps every socket-facing `decode_proto` / `PbDecoder` call
#            alive — most of which (gRPC response bodies, for one) have no
#            prescan in front of them at all.
#
# ⚠ WHY THE PRESCAN OVER-APPROXIMATES, AND WHY THAT IS SOUND. On the raw wire
# a length-delimited record is a nested message, a `string`, or a `bytes` — the
# three are INDISTINGUISHABLE without the schema. The prescan therefore
# descends into EVERY LEN record and abandons a subtree at the first field
# header that does not parse — the decoder's own control flow, over a superset
# of the decoder's descents — which means a string is counted as nesting.
# Apparent depth is thus >= real depth, so a bound on apparent depth is a sound
# bound on the decoder's stack. (A prescan that descends only into payloads
# that parse COMPLETELY is the version one byte defeats, and the
# `>= real depth` claim is FALSE for it.) The cost is the reverse: a plan could
# in principle be refused. That is the risk this file measures rather than
# assumes: `test_the_margin_on_real_plans_is_stated` prints the apparent depth
# of the plans this file builds and requires 4x headroom. The plans are
# hand-built, so it measures the author's imagination; a corpus of real SQL
# plans pushed through a frontend is the wider check, and a false refusal would
# appear there first.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_AND, BIN_GT, BIN_LT
from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SNAPSHOT_PINNED,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import SourceVariant, SOURCE_VARIANT_ORC

# ★ THE GATE IS NOT THE GUARANTEE — so this file reaches PAST it. `decode_proto`
# is what every socket-facing caller uses on bytes off a socket, most of them
# with no admit walk in front at all, and the bound that keeps THEM alive is
# `PbDecoder`'s own recursion count. A test that only ever goes through
# `plan_from_bytes` cannot tell that bound from a comment.
from komira_proto_codec import (
    decode_proto,
    PB_MAX_DECODE_DEPTH,
    PB_DECODE_TOO_DEEP,
)
from komira_plan_proto.plan import WirePlanEnvelope

from komira_plan_wire import (
    plan_to_bytes,
    plan_from_bytes,
    plan_wire_apparent_depth,
    PLAN_WIRE_FORMAT_VERSION,
    PLAN_WIRE_MAX_DEPTH,
    PLAN_WIRE_MAX_NODES,
    PLAN_WIRE_MAX_BYTES,
    PLAN_WIRE_TOO_DEEP,
    PLAN_WIRE_TOO_MANY_NODES,
    PLAN_WIRE_TOO_LARGE,
    PLAN_WIRE_VERSION_MISMATCH,
    PLAN_WIRE_WRITE_TARGET_MIN_VERSION,
    PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED,
    PLAN_WIRE_UNSUPPORTED_WRITE_TARGET,
    PLAN_WIRE_WRITE_TARGET_DROPPED,
    PlanWireVersionSet,
    plan_wire_admit,
    plan_wire_supported_versions,
    plan_to_bytes_with_write_target,
    plan_envelope_from_bytes,
)
from komira_arrow.write_target import (
    WriteTarget,
    WFMT_CSV,
    WFMT_PARQUET,
    WCOMP_SNAPPY,
    WCOMP_UNCOMPRESSED,
    WCOMP_ZSTD,
)


# =============================================================================
# A HOSTILE-MESSAGE BUILDER. Deliberately NOT the codec's encoder.
# =============================================================================
#
# These 30 lines re-implement protobuf framing from the spec, because a hostile
# message is by definition one the encoder would never produce — and a test
# that could only build what the encoder builds is the same closed loop the
# foreign-decode gate was written to break.


def _varint(v: UInt64) -> List[UInt8]:
    """base-128, low group first, continuation bit on every group but the last.
    """
    var out = List[UInt8]()
    var x = v
    while True:
        var group = UInt8(x & 0x7F)
        x >>= 7
        if x != 0:
            out.append(group | 0x80)
        else:
            out.append(group)
            break
    return out^


def _tag(field_no: Int, wire: Int) -> List[UInt8]:
    return _varint(UInt64((field_no << 3) | wire))


def _len_field(field_no: Int, var payload: List[UInt8]) -> List[UInt8]:
    var out = _tag(field_no, 2)
    out.extend(_varint(UInt64(len(payload))))
    out.extend(payload^)
    return out^


def _varint_field(field_no: Int, v: UInt64) -> List[UInt8]:
    var out = _tag(field_no, 0)
    out.extend(_varint(v))
    return out^


def _envelope(version: UInt32, var plan: List[UInt8]) -> List[UInt8]:
    """`WirePlanEnvelope { uint32 format_version = 1; WirePlan plan = 2; }`."""
    var out = _varint_field(1, UInt64(version))
    out.extend(_len_field(2, plan^))
    return out^


def _nested_plan(depth: Int) -> List[UInt8]:
    """A `WirePlan` nested `depth` levels through the FILTER arm.

    `WirePlan.filter = 5` -> `WireFilterNode.child = 2` -> `WirePlan`, so one
    level of plan nesting is two levels of message nesting. Built inside-out:
    the innermost `WirePlan` is the empty message, which is legal proto3."""
    var cur = List[UInt8]()
    for _ in range(depth):
        cur = _len_field(5, _len_field(2, cur^))
    return cur^


def _wide_plan(nodes: Int) -> List[UInt8]:
    """A `WirePlan` whose UNION arm carries `nodes` sibling children.

    `WirePlan.union_all = 13` -> `WireUnionNode.children = 1` (repeated). This
    is the BREADTH attack: depth 3, unbounded node count. A depth bound alone
    does not see it."""
    var kids = List[UInt8]()
    for _ in range(nodes):
        kids.extend(_len_field(1, List[UInt8]()))
    return _len_field(13, kids^)


# =============================================================================
# A legitimate plan, for the leg that says the bounds admit real work.
# =============================================================================


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _scan() raises -> LogicalPlan:
    var p = ScanParams()
    p.put_str(String("path"), String("/data/orders.orc"))
    return LogicalPlan.scan_from_source(
        SourceVariant(
            tag=SOURCE_VARIANT_ORC,
            binding=ScanBinding(
                kind_id=scan_kind_id(String("komira.orc")),
                kind_name=String("komira.orc"),
                name=String("orders"),
                params=p^,
                schema=_schema(),
                fingerprint=UInt64(0xDEADBEEF),
                structural_id=UInt64(0xFEEDFACE),
                gate=PushdownGate.conjunctive_comparison(),
                snapshot_policy=SNAPSHOT_PINNED,
                snapshot_token=UInt64(1234567890),
            ),
        ),
        _schema(),
    )


def _filter_over_scan() raises -> LogicalPlan:
    """`(a > 3) AND (b < 9)` over the scan — two levels of expression nesting
    on top of the plan nesting, which is what makes it the right plan to
    measure APPARENT DEPTH against."""
    return LogicalPlan.filter(
        Expr.binary(
            BIN_AND,
            Expr.binary(
                BIN_GT,
                Expr.col_ref("a"),
                Expr.literal(ScalarValue.from_int64(Int64(3))),
            ),
            Expr.binary(
                BIN_LT,
                Expr.col_ref("b"),
                Expr.literal(ScalarValue.from_int64(Int64(9))),
            ),
        ),
        _scan(),
    )


# =============================================================================
# The refusal assertion. Names the token, and REQUIRES the process to survive.
# =============================================================================


def _assert_refused(
    what: String, bytes: List[UInt8], token: String
) raises:
    var raised = False
    var msg = String("")
    try:
        _ = plan_from_bytes(bytes.copy())
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        what
        + ": plan_from_bytes ACCEPTED "
        + String(len(bytes))
        + " bytes it should have refused. A silent accept is the worst of the"
        + " three unguarded behaviours, because nothing downstream is looking.",
    )
    assert_true(
        token in msg,
        what
        + ": refused, but not by the name that says WHY. Expected the token `"
        + token
        + "`; got `"
        + msg
        + "`. A refusal a caller cannot classify is a refusal a caller cannot"
        + " act on.",
    )
    print("  REFUSED  " + what + "  ->  " + token)


# =============================================================================
# DEPTH
# =============================================================================


def test_a_nest_past_the_bound_is_refused_by_name() raises:
    # ★ THE BOUNDARY, EXACTLY — paired with the vacuity guard below, which
    # admits the nest one level shallower. Together they pin the cap to a
    # single value; either alone would pass with the bound off by any amount in
    # its own direction.
    #
    # THE ARITHMETIC, because it is not obvious and getting it wrong is how
    # this pair stops being a boundary: `_walk` counts the envelope as depth 1
    # and the outermost `WirePlan` as 2, and every plan level adds TWO records
    # (`WirePlan` -> `WireFilterNode` -> `WirePlan`). So `_nested_plan(d)`
    # reaches depth 2 + 2d, and the first REFUSED d is the one where that
    # exceeds 64 — d = 32, giving 66.
    var over = _envelope(
        PLAN_WIRE_FORMAT_VERSION, _nested_plan(PLAN_WIRE_MAX_DEPTH // 2)
    )
    _assert_refused(
        "depth = 66 records, the first over the cap", over, PLAN_WIRE_TOO_DEEP
    )


def test_the_nest_that_killed_the_process_is_now_a_named_refusal() raises:
    # ⚠ THIS IS AN UNGUARDED SIGSEGV, VERBATIM — the 5,941-byte input from the
    # table at the top of this file. Without the prescan it exhausts the stack
    # inside `PbDecoder.read_message` and the process dies with no error at all,
    # so the `try` a caller writes never runs.
    #
    # The smallest measured killer was smaller still (160 levels, 901 bytes).
    # 1,000 is kept because it is the input the VERSION-ordering probe used, so
    # the two legs are driven by the same message.
    var bomb = _envelope(PLAN_WIRE_FORMAT_VERSION, _nested_plan(1000))
    assert_true(
        len(bomb) < 8000,
        "the depth bomb must stay TINY — the entire finding is that a few KB of"
        " input killed the process, and a bomb that grew would quietly become a"
        " test about size instead. It is "
        + String(len(bomb))
        + " bytes.",
    )
    _assert_refused("depth = 1000 (the SIGSEGV)", bomb, PLAN_WIRE_TOO_DEEP)


def test_a_deeper_nest_is_still_a_refusal_and_not_a_crash() raises:
    # 20,000 plan levels = 40,002 wire records, 625x the cap. The bound must be
    # checked as the walk DESCENDS, not computed first and compared after: a
    # prescan that recursed would die here exactly as the decoder did, and one
    # that measured the whole message before comparing would do 40,000 levels of
    # work to refuse at 64.
    #
    # ⚠ 20,000 AND NOT 100,000 FOR A REASON THAT IS ABOUT THIS FILE, NOT THE
    # CODEC. `_nested_plan` builds inside-out and copies the accumulated buffer
    # at every level, so the BUILDER is quadratic; at 100,000 it spent 6.4 s
    # constructing an input the codec then refused in microseconds. The refusal
    # is identical at either size.
    var bomb = _envelope(PLAN_WIRE_FORMAT_VERSION, _nested_plan(20000))
    _assert_refused("depth = 20000", bomb, PLAN_WIRE_TOO_DEEP)


def test_the_depth_bound_is_reached_and_not_merely_survived() raises:
    # ⚠ THE VACUITY GUARD. Every assertion above stays green if the prescan
    # refuses EVERYTHING — including every real plan. This one requires a nest
    # just inside the bound to actually be admitted, so the bound is a bound
    # and not a wall at zero.
    #
    # ⚠ THE `// 2` IS NOT ARITHMETIC TIDINESS — IT IS THE UNIT, and this leg
    # caught the author getting it wrong. `PLAN_WIRE_MAX_DEPTH` counts WIRE
    # RECORDS; a plan level is TWO of them. Written as `MAX_DEPTH - 2` this
    # asked for 126 records against a 64 cap, the nest was refused, and this
    # assertion is what said so.
    #
    # `- 1` from the refused case above, so this is the DEEPEST ADMITTED nest —
    # exactly 64 records. One shallower and the pair would leave a gap the cap
    # could move into with nothing going red.
    var at_bound = _envelope(
        PLAN_WIRE_FORMAT_VERSION, _nested_plan(PLAN_WIRE_MAX_DEPTH // 2 - 1)
    )
    var refused_for_depth = False
    try:
        _ = plan_from_bytes(at_bound.copy())
    except e:
        refused_for_depth = PLAN_WIRE_TOO_DEEP in String(e)
    assert_true(
        not refused_for_depth,
        "a nest INSIDE the bound was refused for depth. The bound admits"
        " nothing, which makes every refusal test above vacuous.",
    )


# =============================================================================
# ★★ ONE TRAILING BYTE — THE WALK THAT BOUNDED A DIFFERENT WALK
# =============================================================================
#
# ⚠ A PRESCAN THAT DESCENDS ONLY INTO PAYLOADS THAT PARSE COMPLETELY refuses a
# clean 200-level nest by name. Append ONE byte to the outermost `WirePlan`
# payload and the SAME nest, one level shallower, SIGSEGVs — 902 bytes, one
# more than the 901-byte crash such a prescan is written against.
#
#   INPUT                                        BYTES   BEHAVIOUR (that prescan)
#   PLAN nesting, 200 levels                     1,141   PLAN_WIRE_TOO_DEEP
#   PLAN nesting, 160 levels + one 0x07            902   ★ SIGSEGV
#   UNION, 200,000 children + one 0x07         400,011   ★ ACCEPTED
#
# (Those byte counts are the framing arithmetic, not estimates — the same
# derivation reproduces the unguarded table's 841 / 901 / 5,941 exactly.)
#
# THE MECHANISM, and it is the reason this is a design defect and not an
# off-by-one. A walk that descends into a LEN payload only when the payload
# parses COMPLETELY — trailing byte included — is defeated by a single `0x07`
# (field 0, wire type 7 — a tag no protobuf has ever had) at the END of the
# outermost payload: the predicate is false, so the walk SKIPS the whole
# subtree, sees apparent depth 1, counts zero nodes, and admits.
# `decode_proto` then recurses in FIELD ORDER and reaches the malformed byte
# only on the way back OUT — 320 frames after the point where it would have
# mattered.
#
# So such a gate bounds a traversal that STOPS WHERE THE DECODER KEEPS GOING,
# and "the admit walk saw depth 1" is a true statement about the wrong walk.
# Both structural budgets fall to the identical byte; the size cap does not,
# because it is O(1) on `len(bytes)` and reads nothing.
#
# ★ THE PROPERTY THIS PACKAGE HOLDS. The walk descends into EVERY
# length-delimited record and abandons a subtree at the first field header that
# does not parse — which is exactly what the decoder does, one stack frame at a
# time. And `PbDecoder` counts its own recursion, so the bound does not depend
# on any walk agreeing with it.


def _trailing_byte(var payload: List[UInt8]) -> List[UInt8]:
    """The whole attack: one byte that no protobuf tag can be.

    `0x07` decodes as field number 0, wire type 7. Field 0 is illegal in every
    version of protobuf and wire type 7 has never existed, so BOTH readers
    reject it — the point is entirely about WHEN each of them gets there."""
    payload.append(0x07)
    return payload^


def test_one_trailing_byte_does_not_hide_the_nest_from_the_gate() raises:
    # ★ THE FALSIFIER. Against a prescan that stops descending this is a
    # SIGSEGV and the process is gone — no assertion below runs, no `except`
    # catches it, the test target reports a signal rather than a failure.
    #
    # 160 plan levels is the smallest nest measured to kill the reader; the
    # trailing byte is what makes such a prescan look away from it.
    var bomb = _envelope(
        PLAN_WIRE_FORMAT_VERSION, _trailing_byte(_nested_plan(160))
    )
    assert_true(
        len(bomb) < 1000,
        "the bypass must stay UNDER A KILOBYTE or it stops being the finding —"
        " it is "
        + String(len(bomb))
        + " bytes.",
    )
    _assert_refused(
        "160 levels + one trailing 0x07 (the bypass)", bomb, PLAN_WIRE_TOO_DEEP
    )


def test_the_trailing_byte_is_what_made_the_two_walks_disagree() raises:
    # ⚠ THE MECHANISM ASSERTION, not a second copy of the one above. The SAME
    # nest with and without the byte must measure the SAME apparent depth. Pre-
    # fix the pair read (322, 1): the byte did not make the message shallower,
    # it made the walk stop looking. A fix that merely raised the cap, or that
    # refused every message ending in 0x07, would leave this red.
    var clean = _envelope(PLAN_WIRE_FORMAT_VERSION, _nested_plan(160))
    var bypass = _envelope(
        PLAN_WIRE_FORMAT_VERSION, _trailing_byte(_nested_plan(160))
    )
    var d_clean = plan_wire_apparent_depth(clean)
    var d_bypass = plan_wire_apparent_depth(bypass)
    print(
        "  APPARENT DEPTH  clean = "
        + String(d_clean)
        + "   with one trailing 0x07 = "
        + String(d_bypass)
    )
    assert_true(
        d_bypass >= d_clean,
        "one appended byte made the walk report a SHALLOWER message ("
        + String(d_bypass)
        + " vs "
        + String(d_clean)
        + "). The walk is bounding a traversal the decoder does not perform,"
        " which is the defect itself and not a symptom of it.",
    )
    assert_true(
        d_bypass > PLAN_WIRE_MAX_DEPTH,
        "the bypass measured apparent depth "
        + String(d_bypass)
        + ", inside the cap of "
        + String(PLAN_WIRE_MAX_DEPTH)
        + ". The walk cannot refuse what it cannot see.",
    )


def test_the_trailing_byte_does_not_hide_the_node_budget_either() raises:
    # ★ THE SECOND BUDGET, SAME BYTE. This one never crashed — it was ACCEPTED,
    # which is worse: 200,000 children materialised because the walk counted
    # zero nodes. A fix aimed only at the stack leaves this green and the
    # breadth attack open.
    var wide = _envelope(
        PLAN_WIRE_FORMAT_VERSION,
        _trailing_byte(_wide_plan(PLAN_WIRE_MAX_NODES + 8)),
    )
    _assert_refused(
        "nodes = MAX_NODES + 8 + one trailing 0x07",
        wide,
        PLAN_WIRE_TOO_MANY_NODES,
    )


def test_the_byte_can_be_anything_the_walk_stops_on() raises:
    # ⚠ ANTI-OVERFIT. `0x07` is one of a family: any trailing byte that is not a
    # complete field header ends the payload mid-parse and produced the same
    # bypass. If a fix special-cased the byte rather than the traversal, these
    # go red and the one above does not.
    #
    #   0x07  field 0, wire 7        — illegal field number AND wire type
    #   0x06  field 0, wire 6        — wire type 6 has never existed
    #   0x0A  field 1, wire 2 (LEN)  — a WELL-FORMED tag whose length varint is
    #                                  missing. This is the one that matters: it
    #                                  is not a "bad byte" by any local test.
    #   0x80  a varint continuation with nothing to continue into
    var tails: List[UInt8] = [0x07, 0x06, 0x0A, 0x80]
    for tail in tails:
        var payload = _nested_plan(160)
        payload.append(tail)
        var bomb = _envelope(PLAN_WIRE_FORMAT_VERSION, payload^)
        _assert_refused(
            "160 levels + trailing byte " + String(Int(tail)),
            bomb,
            PLAN_WIRE_TOO_DEEP,
        )


def test_the_bypass_byte_can_sit_at_any_depth() raises:
    # ⚠ THE OTHER HALF OF THE ANTI-OVERFIT. The simplest bypass puts the byte
    # in the OUTERMOST payload to hide everything below it — but a byte at level k
    # hides everything below k just as well, and a fix that only looked harder
    # at the top level would leave the message one nesting level away from
    # working again.
    #
    # Built inside-out: 40 clean levels wrapped around a payload that is itself
    # a 160-level nest plus the stopper.
    var inner = _trailing_byte(_nested_plan(160))
    for _ in range(40):
        inner = _len_field(5, _len_field(2, inner^))
    var bomb = _envelope(PLAN_WIRE_FORMAT_VERSION, inner^)
    _assert_refused(
        "the stopper buried 40 levels down", bomb, PLAN_WIRE_TOO_DEEP
    )


def test_a_stopper_BEFORE_the_nest_cannot_hide_it_either() raises:
    # ★★ THE SHARPEST PROBE AT THE WALK, AND THE ONE THAT NEARLY WORKS. The walk
    # abandons a subtree at the first field header that does not parse — so
    # put the stopper FIRST and the walk abandons before it ever reaches the
    # nest behind it. That re-creates the bypass exactly, IF the decoder keeps
    # reading where the walk stopped.
    #
    # It does not, and the reason is the invariant the walk rests on: it
    # stops on precisely what the decoder's readers RAISE on, never on anything
    # weaker. Each stopper below is a different one of those conditions —
    #
    #   0x07  field number 0            `pb_read_tag` raises
    #   0x0E  field 1, wire type 6      `pb_skip_field` raises (no such wire)
    #   0x1B  field 3, wire type 3      `pb_skip_field` raises (groups, removed)
    #   0x2A 0xFF...  a LEN whose declared length runs past the record
    #                                   `pb_read_len_field` raises
    #
    # — and every one must be a REFUSAL, by any token, with the process alive.
    # If a future reader ever grows a stopper the walk treats as fatal and the
    # decoder walks past, this is where it shows up.
    var heads = List[List[UInt8]]()
    var h0: List[UInt8] = [0x07]
    var h1: List[UInt8] = [0x0E]
    var h2: List[UInt8] = [0x1B]
    # field 5, wire 2, length 0xFFFFFFFF — declared far past the record's end.
    var h3: List[UInt8] = [0x2A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F]
    heads.append(h0^)
    heads.append(h1^)
    heads.append(h2^)
    heads.append(h3^)
    for i in range(len(heads)):
        var payload = heads[i].copy()
        payload.extend(_nested_plan(160))
        var bomb = _envelope(PLAN_WIRE_FORMAT_VERSION, payload^)
        var raised = False
        try:
            _ = plan_from_bytes(bomb.copy())
        except:
            raised = True
        assert_true(
            raised,
            "a stopper placed BEFORE a 160-level nest was ACCEPTED. The walk"
            " abandoned the subtree at the stopper and the decoder read past"
            " it — which is the 902-byte bypass with the byte moved to the"
            " front. Stopper index "
            + String(i),
        )
    print(
        "  REFUSED  4 leading stoppers, each in front of a 160-level nest"
    )


def test_a_real_plan_with_a_trailing_stopper_is_a_refusal_not_a_crash() raises:
    # The merely-buggy writer, in the shape this section is about: a correct
    # plan whose payload picked up one extra byte. It must be REFUSED — by any
    # token — and the reader must survive. Nothing here asserts WHICH token,
    # because the honest answer is that the bytes are broken in more than one
    # way and either reader may reach its objection first.
    var good = plan_to_bytes(_filter_over_scan())
    var corrupt = good.copy()
    corrupt.append(0x07)
    var raised = False
    try:
        _ = plan_from_bytes(corrupt^)
    except:
        raised = True
    assert_true(
        raised,
        "a plan with one appended byte was ACCEPTED. The trailing byte is not"
        " part of any field, so a reader that admits it is reading a message"
        " nobody wrote.",
    )


# =============================================================================
# ★ THE BOUND THAT IS NOT THIS FORMAT'S — `PbDecoder` COUNTS ITS OWN RECURSION
# =============================================================================
#
# ⚠ EVERY LEG ABOVE GOES THROUGH `plan_from_bytes`, SO EVERY LEG ABOVE IS
# SATISFIED BY THE ADMIT WALK ALONE. Delete `PbDecoder._sub_decoder`'s check and
# they all stay green — which would leave the strongest half of the guarantee
# held by nothing, in a file whose entire subject is gates that hold nothing.
#
# So these two reach the decoder DIRECTLY. They are also the only place the real
# scope of the bound is visible: `decode_proto` is called on bytes that arrive
# over a socket — cloud gRPC responses, policy documents, job payloads — and
# NONE of those has an admit walk. Without this bound every one of them is one
# hostile response away from the same stack dump this file's header records.


def test_the_decoder_refuses_a_deep_message_with_no_gate_in_front() raises:
    # ★ NO `plan_from_bytes`. The bytes go straight to `decode_proto`, exactly
    # as a gRPC response body does. Without the bound this is the SIGSEGV; the
    # walk that would catch it is not in this call path.
    var bomb = _envelope(PLAN_WIRE_FORMAT_VERSION, _nested_plan(1000))
    var raised = False
    var msg = String("")
    try:
        _ = decode_proto[WirePlanEnvelope](bomb.copy())
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "`decode_proto` ACCEPTED a 1000-level nest with no prescan in front of"
        " it. Every socket-facing caller is that call.",
    )
    assert_true(
        PB_DECODE_TOO_DEEP in msg,
        "`decode_proto` refused, but not by the recursion bound — got `"
        + msg
        + "`. If some other check happened to object first, this leg is"
        " asserting nothing about the stack.",
    )
    print(
        "  REFUSED  decode_proto, no gate, 1000 levels  ->  "
        + PB_DECODE_TOO_DEEP
    )


def test_the_decoder_bound_admits_what_it_must() raises:
    # ⚠ THE VACUITY GUARD FOR THE BOUND THAT IS NOT THIS FORMAT'S. A decoder
    # that refuses everything satisfies the leg above. `PB_MAX_DECODE_DEPTH` and
    # `PLAN_WIRE_MAX_DEPTH` are the SAME NUMBER IN THE SAME UNIT deliberately —
    # the walk descends into a superset of the records the decoder recurses
    # into, so a plan the walk ADMITS can never be refused here. This asserts
    # that relationship rather than restating it: the deepest nest the gate
    # admits must decode without a `TOO_DEEP` from the layer underneath.
    assert_equal(
        PB_MAX_DECODE_DEPTH,
        PLAN_WIRE_MAX_DEPTH,
        "the two depth caps have drifted apart. If the decoder's is LOWER,"
        " plans the gate admits now fail with `"
        + PB_DECODE_TOO_DEEP
        + "` from inside the parse, which is the failure this whole file"
        " exists to convert into a named refusal at the door.",
    )
    var at_bound = _envelope(
        PLAN_WIRE_FORMAT_VERSION, _nested_plan(PLAN_WIRE_MAX_DEPTH // 2 - 1)
    )
    var refused_for_depth = False
    try:
        _ = decode_proto[WirePlanEnvelope](at_bound.copy())
    except e:
        refused_for_depth = PB_DECODE_TOO_DEEP in String(e)
    assert_true(
        not refused_for_depth,
        "the deepest nest `plan_wire_admit` admits was refused by the DECODER's"
        " bound. The gate and the thing it protects disagree, so a legitimate"
        " plan is refused by whichever one is stricter.",
    )
    # And a real plan, which is the only input that matters in the end.
    _ = decode_proto[WirePlanEnvelope](plan_to_bytes(_filter_over_scan()))


# =============================================================================
# NODE BUDGET — the breadth attack a depth bound cannot see
# =============================================================================


def test_a_wide_message_past_the_budget_is_refused_by_name() raises:
    var wide = _envelope(
        PLAN_WIRE_FORMAT_VERSION, _wide_plan(PLAN_WIRE_MAX_NODES + 8)
    )
    # Depth 3. A depth bound alone calls this fine.
    assert_true(
        plan_wire_apparent_depth(wide) <= 4,
        "the breadth bomb must be SHALLOW or it is not testing the node budget"
        " — it measured depth "
        + String(plan_wire_apparent_depth(wide)),
    )
    _assert_refused(
        "nodes = MAX_NODES + 8, depth 3", wide, PLAN_WIRE_TOO_MANY_NODES
    )


def test_the_node_budget_is_reached_and_not_merely_survived() raises:
    var under = _envelope(PLAN_WIRE_FORMAT_VERSION, _wide_plan(16))
    var refused_for_nodes = False
    try:
        _ = plan_from_bytes(under.copy())
    except e:
        refused_for_nodes = PLAN_WIRE_TOO_MANY_NODES in String(e)
    assert_true(
        not refused_for_nodes,
        "a 16-child union was refused for the node budget. The budget admits"
        " nothing.",
    )


# =============================================================================
# SIZE CAP
# =============================================================================


def test_bytes_past_the_size_cap_are_refused_without_being_read() raises:
    # A valid one-node plan followed by padding. The plan PARSES; the size is
    # the objection, and it must be raised before anything walks the bytes.
    var big = _envelope(PLAN_WIRE_FORMAT_VERSION, _wide_plan(1))
    while len(big) <= PLAN_WIRE_MAX_BYTES:
        big.append(0)
    _assert_refused("len > MAX_BYTES", big, PLAN_WIRE_TOO_LARGE)


# =============================================================================
# ★ VERSION FIRST — the ordering claim, made falsifiable
# =============================================================================


def test_the_version_gate_fires_before_the_tree_is_parsed() raises:
    # ⚠ HOW THIS LEG WORKS, because it is the subtle one. The message declares
    # version 99 AND carries a 100,000-deep nest. Both are refusable. Which
    # TOKEN comes back says which check ran first:
    #
    #   VERSION_MISMATCH -> the version was read from the top-level field
    #                       stream and refused before anything descended.
    #   TOO_DEEP         -> the structural walk ran first (still safe, but the
    #                       ordering claim is false).
    #   a SIGSEGV        -> the full parse ran first, which is exactly the
    #                       structural absence this file asserts against.
    var hostile = _envelope(99, _nested_plan(20000))
    _assert_refused(
        "version 99 wrapped around a 20000-deep nest",
        hostile,
        PLAN_WIRE_VERSION_MISMATCH,
    )


def test_the_version_gate_still_fires_on_an_otherwise_perfect_message() raises:
    # The same gate on a message that is wrong about NOTHING else — so a reader
    # cannot pass the leg above by refusing every deep message with a version
    # token.
    #
    # ⚠ NOT `PLAN_WIRE_FORMAT_VERSION + 1`: that is a real version (the write
    # envelope). The version check is SET MEMBERSHIP, not `!=`, so "one more
    # than the plain version" is inside the set. The unsupported value has to
    # be derived from the TOP of the set, not from the bottom.
    var good = plan_to_bytes(_filter_over_scan())
    var unsupported = PLAN_WIRE_WRITE_TARGET_MIN_VERSION + 1
    assert_false(
        plan_wire_supported_versions().contains(unsupported),
        "this leg's premise is that "
        + String(Int(unsupported))
        + " is a version this build does not speak, and it now does. Pick a"
        " value outside the set — the point of the leg is the REFUSAL path.",
    )
    var reversioned = _envelope(unsupported, _nested_plan(1))
    _ = good
    _assert_refused(
        "version = WRITE_TARGET_MIN_VERSION + 1",
        reversioned,
        PLAN_WIRE_VERSION_MISMATCH,
    )


def test_a_supported_version_with_no_write_target_is_admitted() raises:
    """★ THE OTHER DIRECTION, AND IT IS THE ONE A `>=` OR A `!=` WOULD GET
    WRONG.

    `PLAN_WIRE_WRITE_TARGET_MIN_VERSION` on an envelope carrying NO write
    target is a producer OVER-DECLARING its reader requirement. That is
    conservative and legal: the version is a MINIMUM READER CAPABILITY, so
    declaring a floor higher than you need can only make an older reader refuse
    bytes it would in fact have handled — never a wrong answer.

    ⚠ WITHOUT THIS LEG, `plan_wire_supported_versions()` could quietly become
    `{PLAN_WIRE_FORMAT_VERSION}` alone and only the write path would notice.
    Here the plain path notices too."""
    var plan_bytes = _envelope(
        PLAN_WIRE_WRITE_TARGET_MIN_VERSION, _nested_plan(1)
    )
    # `_nested_plan(1)` is a FILTER over an empty child, which is a plan the
    # codec refuses on its own terms — the claim here is only that the refusal
    # is NOT the version one.
    var refusal = String("")
    try:
        _ = plan_from_bytes(plan_bytes^)
    except e:
        refusal = String(e)
    assert_false(
        refusal.startswith(PLAN_WIRE_VERSION_MISMATCH),
        "format_version=WRITE_TARGET_MIN_VERSION with no write target must be"
        " ADMITTED by the version"
        " gate (a producer may over-declare its reader floor); got: " + refusal,
    )


# =============================================================================
# MERELY BUGGY BYTES — the writer that is wrong, not hostile
# =============================================================================


def test_a_truncated_message_is_a_refusal_and_not_a_crash() raises:
    var good = plan_to_bytes(_filter_over_scan())
    # Every proper prefix. A writer whose socket closed early produces one of
    # these, and NONE of them may kill the reader.
    var survived = 0
    for cut in range(1, len(good)):
        var truncated = List[UInt8]()
        for i in range(cut):
            truncated.append(good[i])
        try:
            _ = plan_from_bytes(truncated^)
        except:
            pass
        survived += 1
    assert_equal(
        survived,
        len(good) - 1,
        "a truncated message killed the reader",
    )
    print(
        "  SURVIVED "
        + String(survived)
        + " truncations of a "
        + String(len(good))
        + "-byte plan"
    )


def test_a_single_flipped_byte_is_a_refusal_and_not_a_crash() raises:
    var good = plan_to_bytes(_filter_over_scan())
    var survived = 0
    for i in range(len(good)):
        var deltas: List[UInt8] = [1, 0x7F, 0x80, 0xFF]
        for delta in deltas:
            var corrupt = good.copy()
            corrupt[i] = corrupt[i] ^ delta
            try:
                _ = plan_from_bytes(corrupt^)
            except:
                pass
            survived += 1
    assert_true(
        survived == len(good) * 4,
        "a single-byte corruption killed the reader",
    )
    print(
        "  SURVIVED "
        + String(survived)
        + " single-byte corruptions of a "
        + String(len(good))
        + "-byte plan"
    )


def test_an_empty_message_is_a_named_refusal() raises:
    # Zero bytes decodes to `format_version = 0`, which is not this build's
    # version — so the version gate is what should catch it, not a null deref
    # further in.
    _assert_refused(
        "zero bytes", List[UInt8](), PLAN_WIRE_VERSION_MISMATCH
    )


# =============================================================================
# ★ THE BOUNDS MUST ADMIT REAL PLANS — the anti-vacuity leg that matters most
# =============================================================================


def test_real_plans_still_round_trip_under_the_bounds() raises:
    var plans = List[LogicalPlan]()
    plans.append(_scan())
    plans.append(_filter_over_scan())
    for i in range(len(plans)):
        var bytes = plan_to_bytes(plans[i])
        var back = plan_from_bytes(bytes^)
        assert_equal(
            back.structural_hash(),
            plans[i].structural_hash(),
            "a legitimate plan does not round-trip under the bounds."
            " A bound that refuses real work is worse than no bound.",
        )


def test_the_margin_on_real_plans_is_stated() raises:
    # ⚠ THE MEASUREMENT THE OVER-APPROXIMATION OWES. The prescan cannot tell a
    # nested message from a string, so a plan carrying string payloads reads
    # DEEPER than it is. This leg prints the worst apparent depth over the
    # plans this suite builds and requires real headroom under the cap — if the
    # margin ever gets thin, it is thin in the log before it is a false refusal
    # in production.
    var worst = 0
    var plans = List[LogicalPlan]()
    plans.append(_scan())
    plans.append(_filter_over_scan())
    for i in range(len(plans)):
        var d = plan_wire_apparent_depth(plan_to_bytes(plans[i]))
        if d > worst:
            worst = d
    print(
        "  APPARENT DEPTH of real plans: "
        + String(worst)
        + "   cap: "
        + String(PLAN_WIRE_MAX_DEPTH)
    )
    assert_true(
        worst * 4 <= PLAN_WIRE_MAX_DEPTH,
        "the apparent depth of an ordinary plan ("
        + String(worst)
        + ") is within 4x of the cap ("
        + String(PLAN_WIRE_MAX_DEPTH)
        + "). The over-approximation has eaten the margin; either the cap"
        " rises or the prescan needs the schema.",
    )


# =============================================================================
# ★ BYTE IDENTITY IS NOT A PROPERTY OF THIS FORMAT — written down, and shown
# =============================================================================
#
# The concern: "there is no canonical form — dead `WireScalar` slots survive
# decode, survive re-encode, and `__eq__` cannot see them, so two
# byte-different messages are one plan and nothing says which encoding IS the
# plan. Either define the canonical form or write down that byte identity is
# not a property of this format."
#
# ⚠ THIS TEST WRITES IT DOWN, AND IT IS THE SECOND OPTION DELIBERATELY.
# proto3 permits omitting a default-valued scalar, protoc omits them, this
# encoder writes them explicitly, and the golden corpus is 44–58% larger than
# protoc's re-serialization of the identical message (the `.canonical.hex`
# fixtures). Both are legal. Both decode to the same plan. Defining a
# canonical form means changing the encoder to omit defaults, which is a
# format-wide change with its own falsifier, not a line in this file.
#
# What is NOT acceptable is leaving it unstated, because "the bytes are the
# plan" is the assumption a frontend author will make by default and it is
# FALSE here. So:
#
#   THE PLAN IS THE MEANING. `structural_hash` is the identity relation.
#   TWO ENCODINGS OF ONE PLAN MAY DIFFER BYTE FOR BYTE and both are correct.
#   DO NOT compare plan bytes for equality, hash them for a cache key, sign
#   them, or dedupe on them. The golden fixtures are frozen so that a CHANGE is
#   visible in review — they are not a claim that the encoding is unique.


def test_byte_identity_is_not_a_property_of_this_format() raises:
    # The demonstration uses the mechanism that is easiest to reach from here:
    # an ADDITIONAL encoding of the same plan produced by hand — a
    # longer-than-minimal varint for `format_version`, which protobuf permits
    # and every conformant reader accepts. The bytes differ; the plan does not.
    #
    # Field ORDER is another free choice: a plain scalar field may be emitted
    # before or after the `node` oneof. The leg below does not depend on it.
    var plan = _filter_over_scan()
    var canonical = plan_to_bytes(plan)

    # Re-frame the envelope with the SAME plan payload but `format_version`
    # written as a longer-than-minimal varint. Protobuf permits a non-minimal
    # varint encoding and every conformant reader accepts it.
    var plan_payload = List[UInt8]()
    var i = 0
    # Skip the envelope's field-1 varint (tag 0x08 + one byte at this version)
    # and take the rest — the `plan` LEN field, verbatim.
    while i < len(canonical):
        if i >= 2:
            plan_payload.append(canonical[i])
        i += 1
    var padded = List[UInt8]()
    padded.append(0x08)  # field 1, varint
    padded.append(UInt8(Int(PLAN_WIRE_FORMAT_VERSION)) | 0x80)  # continuation
    padded.append(0x00)  # ...with a zero high group. Same value, more bytes.
    padded.extend(plan_payload^)

    assert_true(
        len(padded) != len(canonical),
        "the two encodings are the same length, so this leg is not"
        " demonstrating anything about byte identity.",
    )

    var a = plan_from_bytes(canonical^)
    var b = plan_from_bytes(padded^)
    assert_equal(
        a.structural_hash(),
        b.structural_hash(),
        "★ THE OPPOSITE OF THE INTENDED FINDING. Two legal encodings of one"
        " plan decoded to DIFFERENT plans. If this ever fires, the note above"
        " is wrong in the dangerous direction and the codec has a real defect —"
        " byte identity would be neither guaranteed nor irrelevant.",
    )
    print(
        "  BYTE IDENTITY: two encodings of one plan, "
        + String(a.structural_hash())
        + " both, differing in length. Bytes are not the identity."
    )


# =============================================================================
# THE WRITE ENVELOPE - three falsifiers
# =============================================================================
#
# `WirePlanEnvelope.write_target` is the first field this format has added whose
# OMISSION IS THE FAILURE. Every other field is additive by construction: an
# older reader that skips it gets less information and knows it. A reader that
# skips this one runs the query, returns rows, WRITES NO FILE, and raises
# nothing - which is `PLAN_ENDPOINT_PRODUCER_SQL_WRITE_STATEMENT_DROPPED`(36)
# reproduced one layer down, by the mechanism that was supposed to make 36
# unnecessary.
#
# So the version rule and its two refusals are the load-bearing part, and these
# legs are what make them falsifiable rather than argued.


def _write_target_submessage(
    path: String, fmt_wire: UInt64, codec_wire: UInt64
) -> List[UInt8]:
    """`WireWriteTarget { string path = 1; WriteFormat format = 2;
    WriteCompression codec = 3; }`, built from the spec.

    HAND-BUILT ON PURPOSE, like everything else in this file. The whole point of
    the understated-envelope leg is bytes THE ENCODER CANNOT PRODUCE -
    `plan_to_bytes_with_write_target` derives the version from the shape, so it
    is structurally incapable of writing the message that leg needs."""
    var path_bytes = List[UInt8]()
    for b in path.as_bytes():
        path_bytes.append(b)
    var body = _len_field(1, path_bytes^)
    body.extend(_varint_field(2, fmt_wire))
    body.extend(_varint_field(3, codec_wire))
    return body^


def _write_envelope(
    version: UInt32, var plan: List[UInt8], var target: List[UInt8]
) -> List[UInt8]:
    var out = _varint_field(1, UInt64(version))
    out.extend(_len_field(2, plan^))
    out.extend(_len_field(3, target^))
    return out^


def test_f3_a_reader_pinned_at_the_plain_version_refuses_a_write_envelope() raises:
    """THE FALSIFIER THAT JUSTIFIES BUMPING THE VERSION AT ALL.

    A reader that speaks only the plain version must REFUSE a write-carrying
    envelope BY NAME. If it did not, it would decode the plan, ignore field 3,
    execute, and hand back correct rows with the user's file never written.

    THE PINNED READER IS CONSTRUCTED, NOT SIMULATED. `PlanWireVersionSet` is a
    type precisely so this leg can exist: `only(PLAN_WIRE_FORMAT_VERSION)` IS a
    plain-version reader, and it drives the CURRENT admit pass. A test that
    asserted this by reasoning about what an old binary would do would be a
    comment."""
    var bytes = plan_to_bytes_with_write_target(
        _filter_over_scan(),
        WriteTarget(String("/tmp/f3.parquet"), WFMT_PARQUET, WCOMP_UNCOMPRESSED),
    )
    var plain_only = PlanWireVersionSet.only(PLAN_WIRE_FORMAT_VERSION)
    assert_false(
        plain_only.contains(PLAN_WIRE_WRITE_TARGET_MIN_VERSION),
        "the pinned reader must NOT speak the write version, or this leg proves"
        " nothing",
    )
    var raised = False
    var msg = String("")
    try:
        plan_wire_admit(bytes, plain_only)
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "a reader pinned at the plain version ADMITTED a write-carrying"
        " envelope. It"
        " would then decode the plan, skip field 3, execute, and return rows"
        " with nothing written - the silent-wrong this version bump exists to"
        " make impossible.",
    )
    assert_true(
        msg.startswith(PLAN_WIRE_VERSION_MISMATCH),
        "the refusal must be VERSION_MISMATCH - the frontend's fix is 'upgrade"
        " the reader', and any other token sends them somewhere else. got: "
        + msg,
    )
    # THE CONTROL. The same reader must still admit a PLAIN envelope, or the leg
    # above is satisfied by a reader that refuses everything.
    plan_wire_admit(plan_to_bytes(_filter_over_scan()), plain_only)


def test_an_understated_write_envelope_is_refused_by_name() raises:
    """THE OTHER HALF OF THE VERSION-BUMP FALSIFIER, AND THE ONE THAT COVERS BYTES WE DID NOT WRITE.

    Bumping the WRITER is a claim about envelopes this build produced. This
    format is parsed from bytes some other program produced, so a frontend in
    another language can set `write_target` and declare the plain version - and
    those bytes are executed WRONG by every reader shipped before the field
    existed, while this build could run them perfectly.

    Refusing them is what turns 'declare the write version' from a convention
    a frontend author may forget into a rule the wire enforces on the first
    message."""
    var understated = _write_envelope(
        PLAN_WIRE_FORMAT_VERSION,
        _nested_plan(1),
        _write_target_submessage(String("/tmp/understated.parquet"), 1, 2),
    )
    _assert_refused(
        "write_target under the plain format_version",
        understated,
        PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED,
    )
    # AND IT IS REFUSED BY THE PRESCAN, BEFORE THE TREE IS PARSED - the same
    # ordering claim the version gate makes. `_nested_plan(1)` is a FILTER over
    # an empty child, which the codec refuses on its own terms; if the capability
    # floor ran after the parse, THAT is the token that would come back.
    var raised = False
    var msg = String("")
    try:
        plan_wire_admit(understated, plan_wire_supported_versions())
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "the prescan admitted an understated write envelope")
    assert_true(
        msg.startswith(PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED),
        "the prescan's refusal must be the capability-floor one, from a"
        " top-level field scan with the tree still unread. got: " + msg,
    )


def _redeclared(var bytes: List[UInt8], version: UInt32) raises -> List[UInt8]:
    """`bytes` with its `format_version` set to `version`. The encoder writes
    field 1 first as a one-byte varint (`0x08`, then the version), so the
    rewrite is one byte and the plan behind it is unchanged."""
    assert_true(
        len(bytes) > 2 and bytes[0] == UInt8(0x08) and bytes[1] < UInt8(0x80),
        "the envelope no longer starts with a one-byte format_version varint;"
        " this helper's premise is gone",
    )
    bytes[1] = UInt8(Int(version))
    return bytes^


def test_a_retired_version_is_refused_by_name() raises:
    """Versions 2 and 3 are the layouts with `WireScalar.error_code` (field
    20), which this one reserves. Bytes that declare either are refused by
    `PLAN_WIRE_VERSION_MISMATCH` before the tree is parsed, on a plain envelope
    and on a write-carrying one.

    Each case is a plan this build encodes with only its version byte changed,
    so the version is the one thing refused. With 2 or 3 back in the supported
    set, the plain envelope at 2 decodes and this test fails."""
    var retired = List[UInt32]()
    retired.append(UInt32(2))
    retired.append(UInt32(3))
    var plain = plan_to_bytes(_filter_over_scan())
    var write = plan_to_bytes_with_write_target(
        _filter_over_scan(),
        WriteTarget(String("/tmp/retired.parquet"), WFMT_PARQUET, WCOMP_SNAPPY),
    )
    # THE CONTROL: both envelopes, as encoded, pass the version gate.
    plan_wire_admit(plain, plan_wire_supported_versions())
    plan_wire_admit(write, plan_wire_supported_versions())
    for i in range(len(retired)):
        var v = retired[i]
        _assert_refused(
            "a plain envelope declaring retired version " + String(Int(v)),
            _redeclared(plain.copy(), v),
            PLAN_WIRE_VERSION_MISMATCH,
        )
        _assert_refused(
            "a write envelope declaring retired version " + String(Int(v)),
            _redeclared(write.copy(), v),
            PLAN_WIRE_VERSION_MISMATCH,
        )
        assert_false(
            plan_wire_supported_versions().contains(v),
            "version " + String(Int(v)) + " is back in the supported set",
        )


def test_plan_from_bytes_refuses_a_write_envelope_rather_than_dropping_it() raises:
    """THE RETURN TYPE IS THE ARGUMENT. `plan_from_bytes` hands back a
    `LogicalPlan`, which cannot express a destination - so it REFUSES rather
    than returning a plan that runs and writes nothing.

    THIS IS CODE 36's REASONING APPLIED TO OUR OWN API. The refusal 36 stands in
    front of is 'the bound statement carries the source SELECT's plan with the
    destination beside it, and encoding the plan alone succeeds'. The same
    sentence is true of decoding, one layer down, and the same answer applies."""
    var bytes = plan_to_bytes_with_write_target(
        _filter_over_scan(),
        WriteTarget(String("/tmp/dropped.parquet"), WFMT_PARQUET, WCOMP_SNAPPY),
    )
    _assert_refused(
        "a write envelope through plan_from_bytes",
        bytes,
        PLAN_WIRE_WRITE_TARGET_DROPPED,
    )
    # THE CONTROL: the entry point whose TYPE can hold it does hold it.
    var decoded = plan_envelope_from_bytes(bytes.copy())
    assert_true(
        Bool(decoded.write_target),
        "`plan_envelope_from_bytes` lost the write target the refusal above"
        " exists to protect",
    )


def test_f4_the_write_target_survives_the_round_trip_and_each_field_matters() raises:
    """ROUND TRIP, PLUS A MUTATION OF EACH OF THE THREE FIELDS.

    THE THREE MUTATION LEGS ARE NOT DECORATION. A codec that carried the struct
    and then read a hardcoded value out of it would pass the round trip and fail
    here. The general form of this claim lives in
    `test_plan_wire_round_trip_ir.mojo`'s slot probe (the two `:write` corpus
    envelopes); this is the named, readable instance of it."""
    var target = WriteTarget(
        String("/tmp/f4.parquet"), WFMT_PARQUET, WCOMP_UNCOMPRESSED
    )
    var decoded = plan_envelope_from_bytes(
        plan_to_bytes_with_write_target(_filter_over_scan(), target.copy())
    )
    assert_true(Bool(decoded.write_target), "the write target did not survive")
    var back = decoded.write_target.value().copy()
    assert_equal(back.path, target.path, "path")
    assert_equal(Int(back.fmt), Int(target.fmt), "format")
    assert_equal(Int(back.codec), Int(target.codec), "codec")

    # PATH - a different destination must decode as a different destination.
    var other_path = plan_envelope_from_bytes(
        plan_to_bytes_with_write_target(
            _filter_over_scan(),
            WriteTarget(
                String("/tmp/OTHER.parquet"), WFMT_PARQUET, WCOMP_UNCOMPRESSED
            ),
        )
    )
    assert_true(
        other_path.write_target.value().path != back.path,
        "two destinations decoded to the SAME path - the codec is reading a"
        " hardcoded value, not the wire",
    )

    # FORMAT - parquet vs csv, holding the codec fixed at a value both support.
    var other_fmt = plan_envelope_from_bytes(
        plan_to_bytes_with_write_target(
            _filter_over_scan(),
            WriteTarget(String("/tmp/f4.csv"), WFMT_CSV, WCOMP_UNCOMPRESSED),
        )
    )
    assert_true(
        Int(other_fmt.write_target.value().fmt) != Int(back.fmt),
        "two formats decoded to the SAME format",
    )

    # CODEC - uncompressed vs zstd, holding the format fixed.
    var other_codec = plan_envelope_from_bytes(
        plan_to_bytes_with_write_target(
            _filter_over_scan(),
            WriteTarget(String("/tmp/f4.parquet"), WFMT_PARQUET, WCOMP_ZSTD),
        )
    )
    assert_true(
        Int(other_codec.write_target.value().codec) != Int(back.codec),
        "two codecs decoded to the SAME codec - a wrong codec is a WRONG FILE,"
        " not a decode failure, and no row count or wall clock can see it",
    )


def test_an_unservable_format_codec_pair_is_refused_by_name() raises:
    """BOTH MEMBERS VALID, THE PAIR NOT - and no per-space check can see it.

    `WriteFormat` and `WriteCompression` are INDEPENDENT enums on the wire: 3 x 5
    = 15 encodable combinations against the 13 `SinkVariant` file arms. A
    frontend in any language can author `(csv, snappy)` from the published
    vocabulary alone and both `*_from_wire` calls pass - snappy is a Parquet PAGE
    codec, not a whole-file wrapper. `write_target_supported` is the one table
    that decides the pair, and it is shared with the SQL parser and with
    `plan_write._sink_tag_for`'s arm lookup."""
    var bad_pair = _write_envelope(
        PLAN_WIRE_WRITE_TARGET_MIN_VERSION,
        _nested_plan(1),
        # wire numbers: WFMT_CSV = engine 1 + 1 = 2; WCOMP_SNAPPY = 0 + 1 = 1.
        _write_target_submessage(String("/tmp/nope.csv"), 2, 1),
    )
    _assert_refused(
        "(csv, snappy) - two valid members, no sink arm",
        bad_pair,
        PLAN_WIRE_UNSUPPORTED_WRITE_TARGET,
    )
    # THE EMPTY PATH, for the proto3 reason: a zero-length string is
    # indistinguishable from an absent field, so it is the one value that is
    # certainly not a destination.
    var empty_path = _write_envelope(
        PLAN_WIRE_WRITE_TARGET_MIN_VERSION,
        _nested_plan(1),
        _write_target_submessage(String(""), 1, 2),
    )
    _assert_refused(
        "a write target with an EMPTY path",
        empty_path,
        PLAN_WIRE_UNSUPPORTED_WRITE_TARGET,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_nest_past_the_bound_is_refused_by_name]()
    suite.test[test_the_nest_that_killed_the_process_is_now_a_named_refusal]()
    suite.test[test_a_deeper_nest_is_still_a_refusal_and_not_a_crash]()
    suite.test[test_the_depth_bound_is_reached_and_not_merely_survived]()
    suite.test[test_one_trailing_byte_does_not_hide_the_nest_from_the_gate]()
    suite.test[test_the_trailing_byte_is_what_made_the_two_walks_disagree]()
    suite.test[test_the_trailing_byte_does_not_hide_the_node_budget_either]()
    suite.test[test_the_byte_can_be_anything_the_walk_stops_on]()
    suite.test[test_the_bypass_byte_can_sit_at_any_depth]()
    suite.test[test_a_stopper_BEFORE_the_nest_cannot_hide_it_either]()
    suite.test[
        test_a_real_plan_with_a_trailing_stopper_is_a_refusal_not_a_crash
    ]()
    suite.test[test_the_decoder_refuses_a_deep_message_with_no_gate_in_front]()
    suite.test[test_the_decoder_bound_admits_what_it_must]()
    suite.test[test_a_wide_message_past_the_budget_is_refused_by_name]()
    suite.test[test_the_node_budget_is_reached_and_not_merely_survived]()
    suite.test[test_bytes_past_the_size_cap_are_refused_without_being_read]()
    suite.test[test_the_version_gate_fires_before_the_tree_is_parsed]()
    suite.test[
        test_the_version_gate_still_fires_on_an_otherwise_perfect_message
    ]()
    suite.test[test_a_supported_version_with_no_write_target_is_admitted]()
    suite.test[
        test_f3_a_reader_pinned_at_the_plain_version_refuses_a_write_envelope
    ]()
    suite.test[test_an_understated_write_envelope_is_refused_by_name]()
    suite.test[test_a_retired_version_is_refused_by_name]()
    suite.test[
        test_plan_from_bytes_refuses_a_write_envelope_rather_than_dropping_it
    ]()
    suite.test[
        test_f4_the_write_target_survives_the_round_trip_and_each_field_matters
    ]()
    suite.test[test_an_unservable_format_codec_pair_is_refused_by_name]()
    suite.test[test_a_truncated_message_is_a_refusal_and_not_a_crash]()
    suite.test[test_a_single_flipped_byte_is_a_refusal_and_not_a_crash]()
    suite.test[test_an_empty_message_is_a_named_refusal]()
    suite.test[test_real_plans_still_round_trip_under_the_bounds]()
    suite.test[test_the_margin_on_real_plans_is_stated]()
    suite.test[test_byte_identity_is_not_a_property_of_this_format]()
    suite^.run()
