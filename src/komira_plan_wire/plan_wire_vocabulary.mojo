"""The plan wire vocabulary, first produced from the engine's `comptime`
tag declarations by a vocabulary generator that is not in this
repository; it is now kept in step by hand.

Two tests hold it: tests/test_plan_wire_vocabulary.mojo to the engine
(member counts, wire = engine + 1) and
tests/test_plan_wire_vocabulary_names.mojo to protoc's reading of
`komira_plan_proto/plan_vocabulary.proto` (names, membership, and the
numbers the .proto reserves).

The plan IR's wire vocabulary: the encode/decode between the
engine's `comptime` tag values and their permanent wire numbers.

WIRE NUMBER = ENGINE VALUE + 1. Wire 0 is UNSPECIFIED in every
space, so a proto3 message with an ABSENT tag field cannot decode
as a valid node. Engine tag 0 is a real tag in every space here
(PLAN_SCAN, EXPR_COL_REF, AGG_SUM, JOIN_INNER, ...), so without
the offset a missing field would decode as a valid plan node.

Every `*_from_wire` RAISES on 0 and on an unknown value, by name.
A plan you cannot execute is not a plan you may partially
execute — the unknown-tag rule is fail-loud, deliberately, and
that is what makes a silently-forward-compatible reader
impossible to write by accident.

`*_is_declared` tests membership over the MAXIMAL CONSECUTIVE RUNS
of the declared engine values. It is exact — a run only ever
covers values the engine declares — and it is why this file is
small enough to live in `komira_plan_wire`.

⚠ THE LADDER SHAPE IS LOAD-BEARING — EVERY ARM *WRITES*, IT DOES
NOT *RETURN*. `write_<space>_wire_name[W: Writer](mut writer, wire)`
holds the arms; `<space>_wire_name(wire) -> String` is a thin
wrapper that collects into a `String`. That split is not style.

An N-arm ladder that RETURNS a string literal per arm lowers to TWO
PARALLEL CONSTANT ARRAYS — one of pointers, one of lengths — and
the linker binds a call site's two references INDEPENDENTLY. A
shipped `_komira.dylib` can cross exactly such a pair: a render
reading a JOIN-TYPE index out of another ladder's POINTER array as
if it were a LENGTH makes `komira.Session.sql("... JOIN ...")` take
a SIGSEGV at 0x4 (mac) / a null-alloc SIGABRT (linux). The binding
is a property of the whole link, so it is a LOTTERY over every such
ladder, not a defect of one site.

MEASURED, on these ladders built as a `--emit shared-lib`: the
RETURNING shape emits register-indexed constant-table loads
(`ldr x0, [x8, w19, uxtw #3]`); the WRITING shape plus the `String`
wrapper emits ZERO, and both render byte-identical text. A small
synthetic does NOT reproduce the crossing, so the source shape —
not a compiler flag — is the defence available.

⇒ DO NOT collapse the wrapper back into a returning ladder, here or
in the generator. A repository lint fails if you do.
"""


comptime PLAN_WIRE_UNSPECIFIED_VALUE: Int32 = 0
"""Wire 0, in every space. Never a valid tag."""

comptime PLAN_WIRE_VOCABULARY_MEMBERS: Int = 352
"""Total published members across all 32 spaces. A drift tripwire a test can pin."""

comptime PLAN_WIRE_SPACE_COUNT: Int = 32
"""Number of enumerated tag spaces the vocabulary publishes."""


# ==========================================================================
# PlanTag — engine prefix `PLAN_`
# LogicalPlan node kind. ONE declaration site, logical_plan.mojo (0-15).
# 16-17 were the ROW<->COLUMN converts and are DELETED; their numbers stay
# burned.
# Declared in: src/komira_plan_ir/logical_plan.mojo
# ==========================================================================

comptime PLAN_TAG_WIRE_MEMBERS: Int = 16
comptime PLAN_TAG_ENGINE_MIN: UInt8 = 0
comptime PLAN_TAG_ENGINE_MAX: UInt8 = 15
comptime PLAN_TAG_WIRE_MIN: Int32 = 1
comptime PLAN_TAG_WIRE_MAX: Int32 = 16


def plan_tag_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this PlanTag value?

    Runs: [(0, 15)]. Total, never raising.
    """
    return engine_tag <= 15


def plan_tag_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for PlanTag.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not plan_tag_is_declared(engine_tag):
        raise Error("PlanTag: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def plan_tag_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for PlanTag.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("PlanTag: wire value " + String(Int(wire))
            + " is negative; no PlanTag value has a negative wire number")
    if wire == 0:
        raise Error("PlanTag: wire 0 is PLAN_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("PlanTag: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not plan_tag_is_declared(engine_tag):
        raise Error("PlanTag: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_plan_tag_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a PlanTag value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("PLAN_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("PLAN_SCAN")
        return
    if wire == 2:
        writer.write("PLAN_FILTER")
        return
    if wire == 3:
        writer.write("PLAN_PROJECT")
        return
    if wire == 4:
        writer.write("PLAN_AGGREGATE")
        return
    if wire == 5:
        writer.write("PLAN_JOIN")
        return
    if wire == 6:
        writer.write("PLAN_SORT")
        return
    if wire == 7:
        writer.write("PLAN_LIMIT")
        return
    if wire == 8:
        writer.write("PLAN_DISTINCT")
        return
    if wire == 9:
        writer.write("PLAN_TOPN")
        return
    if wire == 10:
        writer.write("PLAN_PARTITION_BY")
        return
    if wire == 11:
        writer.write("PLAN_PARTITION_TOPN")
        return
    if wire == 12:
        writer.write("PLAN_ASOF_JOIN")
        return
    if wire == 13:
        writer.write("PLAN_UNION")
        return
    if wire == 14:
        writer.write("PLAN_VIEW_REF")
        return
    if wire == 15:
        writer.write("PLAN_CSE_REF")
        return
    if wire == 16:
        writer.write("PLAN_CAST_TO_VARCHAR")
        return
    writer.write("PlanTag#", Int(wire))


def plan_tag_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a PlanTag value, as a String.

    A thin `String`-collecting wrapper over
    `write_plan_tag_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_plan_tag_wire_name(out, wire)
    return out^


# ==========================================================================
# ExprTag — engine prefix `EXPR_`
# Expr node kind. EXPR_CORRELATED_SUBQUERY is the only cross-edge from the
# expression tree back into the plan tree.
# Declared in: src/komira_plan_expr/expr.mojo
#
# EXEMPT — declared by the engine and named here, but its wire number
# is RESERVED in plan_vocabulary.proto, so `expr_tag_to_wire` and
# `expr_tag_from_wire` both refuse it (`_expr_tag_is_reserved_on_wire`).
# Each row is a debt with a named blocker; the row disappears when it is
# paid.
#   EXPR_BETWEEN: declared with no payload field on Expr — the SQL frontend desugars
#     BETWEEN into two comparisons, so no Expr in the tree carries this
#     tag
#   EXPR_SORT_KEY: declared with no payload field on Expr — sort keys live on
#     SortData/TopNData, not as an Expr arm
# ==========================================================================

comptime EXPR_TAG_WIRE_MEMBERS: Int = 27
comptime EXPR_TAG_ENGINE_MIN: UInt8 = 0
comptime EXPR_TAG_ENGINE_MAX: UInt8 = 26
comptime EXPR_TAG_WIRE_MIN: Int32 = 1
comptime EXPR_TAG_WIRE_MAX: Int32 = 27


def expr_tag_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this ExprTag value?

    Runs: [(0, 26)]. Total, never raising.
    """
    return engine_tag <= 26


def expr_tag_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for ExprTag.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not expr_tag_is_declared(engine_tag):
        raise Error("ExprTag: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    if _expr_tag_is_reserved_on_wire(engine_tag):
        raise Error("ExprTag: engine tag " + String(Int(engine_tag)) + " ("
            + expr_tag_wire_name(Int32(Int(engine_tag)) + 1)
            + ") is reserved on the wire: plan_vocabulary.proto keeps it off")
    return Int32(Int(engine_tag)) + 1


def _expr_tag_is_reserved_on_wire(engine_tag: UInt8) -> Bool:
    """The EXEMPT rows above: EXPR_BETWEEN (10) and EXPR_SORT_KEY (11).

    The engine declares both, so `expr_tag_is_declared` is true for them;
    plan_vocabulary.proto reserves their wire numbers (11 and 12), so
    neither direction may carry them."""
    return engine_tag == 10 or engine_tag == 11


def expr_tag_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for ExprTag.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("ExprTag: wire value " + String(Int(wire))
            + " is negative; no ExprTag value has a negative wire number")
    if wire == 0:
        raise Error("ExprTag: wire 0 is EXPR_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("ExprTag: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not expr_tag_is_declared(engine_tag):
        raise Error("ExprTag: wire value " + String(Int(wire))
            + " is unknown to this reader")
    if _expr_tag_is_reserved_on_wire(engine_tag):
        raise Error("ExprTag: wire value " + String(Int(wire)) + " ("
            + expr_tag_wire_name(wire)
            + ") is reserved: plan_vocabulary.proto keeps it off the wire")
    return engine_tag


def write_expr_tag_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a ExprTag value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("EXPR_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("EXPR_COL_REF")
        return
    if wire == 2:
        writer.write("EXPR_COL_IDX")
        return
    if wire == 3:
        writer.write("EXPR_LITERAL")
        return
    if wire == 4:
        writer.write("EXPR_BINARY_OP")
        return
    if wire == 5:
        writer.write("EXPR_UNARY_OP")
        return
    if wire == 6:
        writer.write("EXPR_CAST")
        return
    if wire == 7:
        writer.write("EXPR_ALIAS")
        return
    if wire == 8:
        writer.write("EXPR_STRING_OP")
        return
    if wire == 9:
        writer.write("EXPR_WHEN")
        return
    if wire == 10:
        writer.write("EXPR_IN_LIST")
        return
    if wire == 11:
        writer.write("EXPR_BETWEEN")
        return
    if wire == 12:
        writer.write("EXPR_SORT_KEY")
        return
    if wire == 13:
        writer.write("EXPR_AGG_FN")
        return
    if wire == 14:
        writer.write("EXPR_WINDOW_FN")
        return
    if wire == 15:
        writer.write("EXPR_CORRELATED_SUBQUERY")
        return
    if wire == 16:
        writer.write("EXPR_REGEXP")
        return
    if wire == 17:
        writer.write("EXPR_STRUCT_FIELD")
        return
    if wire == 18:
        writer.write("EXPR_STRUCT_FIELD_IDX")
        return
    if wire == 19:
        writer.write("EXPR_MAP_GET")
        return
    if wire == 20:
        writer.write("EXPR_JSON_EXTRACT")
        return
    if wire == 21:
        writer.write("EXPR_EXTRACT")
        return
    if wire == 22:
        writer.write("EXPR_MATH_FN")
        return
    if wire == 23:
        writer.write("EXPR_MATH_FN2")
        return
    if wire == 24:
        writer.write("EXPR_SUBSTRING")
        return
    if wire == 25:
        writer.write("EXPR_STRING_FN")
        return
    if wire == 26:
        writer.write("EXPR_UDF_CALL")
        return
    if wire == 27:
        writer.write("EXPR_STRING_FN_N")
        return
    writer.write("ExprTag#", Int(wire))


def expr_tag_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a ExprTag value, as a String.

    A thin `String`-collecting wrapper over
    `write_expr_tag_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_expr_tag_wire_name(out, wire)
    return out^


# ==========================================================================
# AggFn — engine prefix `AGG_`
# Aggregate function. THE ENGINE HAS NO COUNT CONSTANT FOR THIS SPACE —
# a drift hazard, and it is why count_const is empty here rather than
# guessed.
# Declared in: src/komira_plan_expr/agg_expr.mojo
# ==========================================================================

comptime AGG_FN_WIRE_MEMBERS: Int = 37
comptime AGG_FN_ENGINE_MIN: UInt8 = 0
comptime AGG_FN_ENGINE_MAX: UInt8 = 36
comptime AGG_FN_WIRE_MIN: Int32 = 1
comptime AGG_FN_WIRE_MAX: Int32 = 37


def agg_fn_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this AggFn value?

    Runs: [(0, 36)]. Total, never raising.
    """
    return engine_tag <= 36


def agg_fn_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for AggFn.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not agg_fn_is_declared(engine_tag):
        raise Error("AggFn: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def agg_fn_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for AggFn.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("AggFn: wire value " + String(Int(wire))
            + " is negative; no AggFn value has a negative wire number")
    if wire == 0:
        raise Error("AggFn: wire 0 is AGG_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("AggFn: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not agg_fn_is_declared(engine_tag):
        raise Error("AggFn: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_agg_fn_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a AggFn value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("AGG_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("AGG_SUM")
        return
    if wire == 2:
        writer.write("AGG_COUNT")
        return
    if wire == 3:
        writer.write("AGG_MIN")
        return
    if wire == 4:
        writer.write("AGG_MAX")
        return
    if wire == 5:
        writer.write("AGG_MEAN")
        return
    if wire == 6:
        writer.write("AGG_COUNT_DISTINCT")
        return
    if wire == 7:
        writer.write("AGG_FIRST")
        return
    if wire == 8:
        writer.write("AGG_LAST")
        return
    if wire == 9:
        writer.write("AGG_STDDEV_SAMP")
        return
    if wire == 10:
        writer.write("AGG_CORR")
        return
    if wire == 11:
        writer.write("AGG_MEDIAN")
        return
    if wire == 12:
        writer.write("AGG_LARGEST_K")
        return
    if wire == 13:
        writer.write("AGG_VAR_SAMP")
        return
    if wire == 14:
        writer.write("AGG_COVAR_POP")
        return
    if wire == 15:
        writer.write("AGG_COVAR_SAMP")
        return
    if wire == 16:
        writer.write("AGG_REGR_AVGX")
        return
    if wire == 17:
        writer.write("AGG_REGR_AVGY")
        return
    if wire == 18:
        writer.write("AGG_REGR_COUNT")
        return
    if wire == 19:
        writer.write("AGG_REGR_SXX")
        return
    if wire == 20:
        writer.write("AGG_REGR_SXY")
        return
    if wire == 21:
        writer.write("AGG_REGR_SYY")
        return
    if wire == 22:
        writer.write("AGG_REGR_SLOPE")
        return
    if wire == 23:
        writer.write("AGG_REGR_INTERCEPT")
        return
    if wire == 24:
        writer.write("AGG_REGR_R2")
        return
    if wire == 25:
        writer.write("AGG_VAR_POP")
        return
    if wire == 26:
        writer.write("AGG_STDDEV_POP")
        return
    if wire == 27:
        writer.write("AGG_SEM")
        return
    if wire == 28:
        writer.write("AGG_COUNT_IF")
        return
    if wire == 29:
        writer.write("AGG_BOOL_AND")
        return
    if wire == 30:
        writer.write("AGG_BOOL_OR")
        return
    if wire == 31:
        writer.write("AGG_PRODUCT")
        return
    if wire == 32:
        writer.write("AGG_ANY_VALUE")
        return
    if wire == 33:
        writer.write("AGG_KAHAN_SUM")
        return
    if wire == 34:
        writer.write("AGG_KAHAN_AVG")
        return
    if wire == 35:
        writer.write("AGG_SKEWNESS")
        return
    if wire == 36:
        writer.write("AGG_KURTOSIS")
        return
    if wire == 37:
        writer.write("AGG_KURTOSIS_POP")
        return
    writer.write("AggFn#", Int(wire))


def agg_fn_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a AggFn value, as a String.

    A thin `String`-collecting wrapper over
    `write_agg_fn_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_agg_fn_wire_name(out, wire)
    return out^


# ==========================================================================
# WindowFn — engine prefix `PF_`
# Window / partition function. The engine numbering is SPARSE (ranking
# 0-5, offset 10-14, aggregate 20-24); the gaps are unallocated, not
# retired, and stay allocatable.
# Declared in: src/komira_plan_expr/partition_expr.mojo
# ==========================================================================

comptime WINDOW_FN_WIRE_MEMBERS: Int = 16
comptime WINDOW_FN_ENGINE_MIN: UInt8 = 0
comptime WINDOW_FN_ENGINE_MAX: UInt8 = 24
comptime WINDOW_FN_WIRE_MIN: Int32 = 1
comptime WINDOW_FN_WIRE_MAX: Int32 = 25


def window_fn_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this WindowFn value?

    Runs: [(0, 5), (10, 14), (20, 24)]. Total, never raising.
    """
    return engine_tag <= 5 or (engine_tag >= 10 and engine_tag <= 14) or (engine_tag >= 20 and engine_tag <= 24)


def window_fn_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for WindowFn.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not window_fn_is_declared(engine_tag):
        raise Error("WindowFn: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def window_fn_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for WindowFn.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("WindowFn: wire value " + String(Int(wire))
            + " is negative; no WindowFn value has a negative wire number")
    if wire == 0:
        raise Error("WindowFn: wire 0 is PF_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("WindowFn: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not window_fn_is_declared(engine_tag):
        raise Error("WindowFn: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_window_fn_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a WindowFn value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("PF_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("PF_ROW_NUMBER")
        return
    if wire == 2:
        writer.write("PF_RANK")
        return
    if wire == 3:
        writer.write("PF_DENSE_RANK")
        return
    if wire == 4:
        writer.write("PF_PERCENT_RANK")
        return
    if wire == 5:
        writer.write("PF_CUME_DIST")
        return
    if wire == 6:
        writer.write("PF_NTILE")
        return
    if wire == 11:
        writer.write("PF_LAG")
        return
    if wire == 12:
        writer.write("PF_LEAD")
        return
    if wire == 13:
        writer.write("PF_FIRST_VALUE")
        return
    if wire == 14:
        writer.write("PF_LAST_VALUE")
        return
    if wire == 15:
        writer.write("PF_NTH_VALUE")
        return
    if wire == 21:
        writer.write("PF_SUM")
        return
    if wire == 22:
        writer.write("PF_AVG")
        return
    if wire == 23:
        writer.write("PF_COUNT")
        return
    if wire == 24:
        writer.write("PF_MIN")
        return
    if wire == 25:
        writer.write("PF_MAX")
        return
    writer.write("WindowFn#", Int(wire))


def window_fn_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a WindowFn value, as a String.

    A thin `String`-collecting wrapper over
    `write_window_fn_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_window_fn_wire_name(out, wire)
    return out^


# ==========================================================================
# FrameUnits — engine prefix `FRAME_UNITS_`
# Window frame units — ROWS vs RANGE.
# Declared in: src/komira_plan_expr/partition_frame.mojo
# ==========================================================================

comptime FRAME_UNITS_WIRE_MEMBERS: Int = 2
comptime FRAME_UNITS_ENGINE_MIN: UInt8 = 0
comptime FRAME_UNITS_ENGINE_MAX: UInt8 = 1
comptime FRAME_UNITS_WIRE_MIN: Int32 = 1
comptime FRAME_UNITS_WIRE_MAX: Int32 = 2


def frame_units_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this FrameUnits value?

    Runs: [(0, 1)]. Total, never raising.
    """
    return engine_tag <= 1


def frame_units_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for FrameUnits.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not frame_units_is_declared(engine_tag):
        raise Error("FrameUnits: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def frame_units_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for FrameUnits.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("FrameUnits: wire value " + String(Int(wire))
            + " is negative; no FrameUnits value has a negative wire number")
    if wire == 0:
        raise Error("FrameUnits: wire 0 is FRAME_UNITS_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("FrameUnits: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not frame_units_is_declared(engine_tag):
        raise Error("FrameUnits: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_frame_units_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a FrameUnits value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("FRAME_UNITS_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("FRAME_UNITS_ROWS")
        return
    if wire == 2:
        writer.write("FRAME_UNITS_RANGE")
        return
    writer.write("FrameUnits#", Int(wire))


def frame_units_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a FrameUnits value, as a String.

    A thin `String`-collecting wrapper over
    `write_frame_units_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_frame_units_wire_name(out, wire)
    return out^


# ==========================================================================
# FrameBound — engine prefix `FRAME_BOUND_`
# Window frame boundary kind.
# Declared in: src/komira_plan_expr/partition_frame.mojo
# ==========================================================================

comptime FRAME_BOUND_WIRE_MEMBERS: Int = 5
comptime FRAME_BOUND_ENGINE_MIN: UInt8 = 0
comptime FRAME_BOUND_ENGINE_MAX: UInt8 = 4
comptime FRAME_BOUND_WIRE_MIN: Int32 = 1
comptime FRAME_BOUND_WIRE_MAX: Int32 = 5


def frame_bound_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this FrameBound value?

    Runs: [(0, 4)]. Total, never raising.
    """
    return engine_tag <= 4


def frame_bound_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for FrameBound.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not frame_bound_is_declared(engine_tag):
        raise Error("FrameBound: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def frame_bound_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for FrameBound.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("FrameBound: wire value " + String(Int(wire))
            + " is negative; no FrameBound value has a negative wire number")
    if wire == 0:
        raise Error("FrameBound: wire 0 is FRAME_BOUND_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("FrameBound: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not frame_bound_is_declared(engine_tag):
        raise Error("FrameBound: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_frame_bound_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a FrameBound value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("FRAME_BOUND_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("FRAME_BOUND_UNBOUNDED_PRECEDING")
        return
    if wire == 2:
        writer.write("FRAME_BOUND_PRECEDING")
        return
    if wire == 3:
        writer.write("FRAME_BOUND_CURRENT_ROW")
        return
    if wire == 4:
        writer.write("FRAME_BOUND_FOLLOWING")
        return
    if wire == 5:
        writer.write("FRAME_BOUND_UNBOUNDED_FOLLOWING")
        return
    writer.write("FrameBound#", Int(wire))


def frame_bound_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a FrameBound value, as a String.

    A thin `String`-collecting wrapper over
    `write_frame_bound_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_frame_bound_wire_name(out, wire)
    return out^


# ==========================================================================
# JoinType — engine prefix `JOIN_`
# Join type. THIS IS THE SPACE THE MOTIVATING FAILURE IS ABOUT:
# JoinData.join_type is a bare UInt8, so adding an arm here is invisible
# to every compiler in the pipeline.
# Declared in: src/komira_plan_ir/logical_plan.mojo
# ==========================================================================

comptime JOIN_TYPE_WIRE_MEMBERS: Int = 7
comptime JOIN_TYPE_ENGINE_MIN: UInt8 = 0
comptime JOIN_TYPE_ENGINE_MAX: UInt8 = 6
comptime JOIN_TYPE_WIRE_MIN: Int32 = 1
comptime JOIN_TYPE_WIRE_MAX: Int32 = 7


def join_type_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this JoinType value?

    Runs: [(0, 6)]. Total, never raising.
    """
    return engine_tag <= 6


def join_type_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for JoinType.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not join_type_is_declared(engine_tag):
        raise Error("JoinType: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def join_type_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for JoinType.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("JoinType: wire value " + String(Int(wire))
            + " is negative; no JoinType value has a negative wire number")
    if wire == 0:
        raise Error("JoinType: wire 0 is JOIN_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("JoinType: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not join_type_is_declared(engine_tag):
        raise Error("JoinType: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_join_type_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a JoinType value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("JOIN_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("JOIN_INNER")
        return
    if wire == 2:
        writer.write("JOIN_LEFT")
        return
    if wire == 3:
        writer.write("JOIN_RIGHT")
        return
    if wire == 4:
        writer.write("JOIN_FULL")
        return
    if wire == 5:
        writer.write("JOIN_SEMI")
        return
    if wire == 6:
        writer.write("JOIN_ANTI")
        return
    if wire == 7:
        writer.write("JOIN_CROSS")
        return
    writer.write("JoinType#", Int(wire))


def join_type_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a JoinType value, as a String.

    A thin `String`-collecting wrapper over
    `write_join_type_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_join_type_wire_name(out, wire)
    return out^


# ==========================================================================
# JoinAlgo — engine prefix `JOIN_ALGO_`
# Physical join algorithm hint carried on the logical node.
# Declared in: src/komira_plan_ir/logical_plan.mojo
# ==========================================================================

comptime JOIN_ALGO_WIRE_MEMBERS: Int = 3
comptime JOIN_ALGO_ENGINE_MIN: UInt8 = 0
comptime JOIN_ALGO_ENGINE_MAX: UInt8 = 2
comptime JOIN_ALGO_WIRE_MIN: Int32 = 1
comptime JOIN_ALGO_WIRE_MAX: Int32 = 3


def join_algo_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this JoinAlgo value?

    Runs: [(0, 2)]. Total, never raising.
    """
    return engine_tag <= 2


def join_algo_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for JoinAlgo.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not join_algo_is_declared(engine_tag):
        raise Error("JoinAlgo: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def join_algo_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for JoinAlgo.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("JoinAlgo: wire value " + String(Int(wire))
            + " is negative; no JoinAlgo value has a negative wire number")
    if wire == 0:
        raise Error("JoinAlgo: wire 0 is JOIN_ALGO_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("JoinAlgo: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not join_algo_is_declared(engine_tag):
        raise Error("JoinAlgo: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_join_algo_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a JoinAlgo value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("JOIN_ALGO_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("JOIN_ALGO_AUTO")
        return
    if wire == 2:
        writer.write("JOIN_ALGO_HASH")
        return
    if wire == 3:
        writer.write("JOIN_ALGO_SORT_MERGE")
        return
    writer.write("JoinAlgo#", Int(wire))


def join_algo_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a JoinAlgo value, as a String.

    A thin `String`-collecting wrapper over
    `write_join_algo_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_join_algo_wire_name(out, wire)
    return out^


# ==========================================================================
# AsofDirection — engine prefix `ASOF_`
# AS-OF join match direction.
# Declared in: src/komira_plan_ir/logical_plan.mojo
# ==========================================================================

comptime ASOF_DIRECTION_WIRE_MEMBERS: Int = 3
comptime ASOF_DIRECTION_ENGINE_MIN: UInt8 = 0
comptime ASOF_DIRECTION_ENGINE_MAX: UInt8 = 2
comptime ASOF_DIRECTION_WIRE_MIN: Int32 = 1
comptime ASOF_DIRECTION_WIRE_MAX: Int32 = 3


def asof_direction_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this AsofDirection value?

    Runs: [(0, 2)]. Total, never raising.
    """
    return engine_tag <= 2


def asof_direction_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for AsofDirection.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not asof_direction_is_declared(engine_tag):
        raise Error("AsofDirection: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def asof_direction_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for AsofDirection.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("AsofDirection: wire value " + String(Int(wire))
            + " is negative; no AsofDirection value has a negative wire number")
    if wire == 0:
        raise Error("AsofDirection: wire 0 is ASOF_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("AsofDirection: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not asof_direction_is_declared(engine_tag):
        raise Error("AsofDirection: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_asof_direction_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a AsofDirection value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("ASOF_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("ASOF_BACKWARD")
        return
    if wire == 2:
        writer.write("ASOF_FORWARD")
        return
    if wire == 3:
        writer.write("ASOF_NEAREST")
        return
    writer.write("AsofDirection#", Int(wire))


def asof_direction_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a AsofDirection value, as a String.

    A thin `String`-collecting wrapper over
    `write_asof_direction_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_asof_direction_wire_name(out, wire)
    return out^


# ==========================================================================
# AsofToleranceKind — engine prefix `ASOF_TOL_`
# AS-OF join tolerance representation.
# Declared in: src/komira_plan_ir/logical_plan.mojo
# ==========================================================================

comptime ASOF_TOLERANCE_KIND_WIRE_MEMBERS: Int = 3
comptime ASOF_TOLERANCE_KIND_ENGINE_MIN: UInt8 = 0
comptime ASOF_TOLERANCE_KIND_ENGINE_MAX: UInt8 = 2
comptime ASOF_TOLERANCE_KIND_WIRE_MIN: Int32 = 1
comptime ASOF_TOLERANCE_KIND_WIRE_MAX: Int32 = 3


def asof_tolerance_kind_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this AsofToleranceKind value?

    Runs: [(0, 2)]. Total, never raising.
    """
    return engine_tag <= 2


def asof_tolerance_kind_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for AsofToleranceKind.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not asof_tolerance_kind_is_declared(engine_tag):
        raise Error("AsofToleranceKind: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def asof_tolerance_kind_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for AsofToleranceKind.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("AsofToleranceKind: wire value " + String(Int(wire))
            + " is negative; no AsofToleranceKind value has a negative wire number")
    if wire == 0:
        raise Error("AsofToleranceKind: wire 0 is ASOF_TOL_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("AsofToleranceKind: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not asof_tolerance_kind_is_declared(engine_tag):
        raise Error("AsofToleranceKind: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_asof_tolerance_kind_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a AsofToleranceKind value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("ASOF_TOL_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("ASOF_TOL_NONE")
        return
    if wire == 2:
        writer.write("ASOF_TOL_INT64")
        return
    if wire == 3:
        writer.write("ASOF_TOL_FLOAT64")
        return
    writer.write("AsofToleranceKind#", Int(wire))


def asof_tolerance_kind_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a AsofToleranceKind value, as a String.

    A thin `String`-collecting wrapper over
    `write_asof_tolerance_kind_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_asof_tolerance_kind_wire_name(out, wire)
    return out^


# ==========================================================================
# CorrelatedKind — engine prefix `CORR_KIND_`
# Correlated-subquery flavour (EXISTS / NOT EXISTS / scalar / IN).
# Declared in: src/komira_plan_expr/corr_subquery_data.mojo
# ==========================================================================

comptime CORRELATED_KIND_WIRE_MEMBERS: Int = 4
comptime CORRELATED_KIND_ENGINE_MIN: UInt8 = 0
comptime CORRELATED_KIND_ENGINE_MAX: UInt8 = 3
comptime CORRELATED_KIND_WIRE_MIN: Int32 = 1
comptime CORRELATED_KIND_WIRE_MAX: Int32 = 4


def correlated_kind_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this CorrelatedKind value?

    Runs: [(0, 3)]. Total, never raising.
    """
    return engine_tag <= 3


def correlated_kind_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for CorrelatedKind.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not correlated_kind_is_declared(engine_tag):
        raise Error("CorrelatedKind: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def correlated_kind_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for CorrelatedKind.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("CorrelatedKind: wire value " + String(Int(wire))
            + " is negative; no CorrelatedKind value has a negative wire number")
    if wire == 0:
        raise Error("CorrelatedKind: wire 0 is CORR_KIND_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("CorrelatedKind: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not correlated_kind_is_declared(engine_tag):
        raise Error("CorrelatedKind: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_correlated_kind_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a CorrelatedKind value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("CORR_KIND_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("CORR_KIND_EXISTS")
        return
    if wire == 2:
        writer.write("CORR_KIND_NOT_EXISTS")
        return
    if wire == 3:
        writer.write("CORR_KIND_SCALAR")
        return
    if wire == 4:
        writer.write("CORR_KIND_IN_CORRELATED")
        return
    writer.write("CorrelatedKind#", Int(wire))


def correlated_kind_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a CorrelatedKind value, as a String.

    A thin `String`-collecting wrapper over
    `write_correlated_kind_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_correlated_kind_wire_name(out, wire)
    return out^


# ==========================================================================
# SourceType — engine prefix `SOURCE_`
# ScanData.source_type — the plan-node-level source discriminator.
# SOURCE_BINDING is the pure-data arm every other arm is converging onto.
# Declared in: src/komira_plan_ir/logical_plan.mojo
# ==========================================================================

comptime SOURCE_TYPE_WIRE_MEMBERS: Int = 9
comptime SOURCE_TYPE_ENGINE_MIN: UInt8 = 0
comptime SOURCE_TYPE_ENGINE_MAX: UInt8 = 8
comptime SOURCE_TYPE_WIRE_MIN: Int32 = 1
comptime SOURCE_TYPE_WIRE_MAX: Int32 = 9


def source_type_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this SourceType value?

    Runs: [(0, 8)]. Total, never raising.
    """
    return engine_tag <= 8


def source_type_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for SourceType.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not source_type_is_declared(engine_tag):
        raise Error("SourceType: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def source_type_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for SourceType.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("SourceType: wire value " + String(Int(wire))
            + " is negative; no SourceType value has a negative wire number")
    if wire == 0:
        raise Error("SourceType: wire 0 is SOURCE_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("SourceType: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not source_type_is_declared(engine_tag):
        raise Error("SourceType: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_source_type_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a SourceType value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("SOURCE_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("SOURCE_PARQUET")
        return
    if wire == 2:
        writer.write("SOURCE_CSV")
        return
    if wire == 3:
        writer.write("SOURCE_NDJSON")
        return
    if wire == 4:
        writer.write("SOURCE_IN_MEMORY")
        return
    if wire == 5:
        writer.write("SOURCE_JSON")
        return
    if wire == 6:
        writer.write("SOURCE_ORC")
        return
    if wire == 7:
        writer.write("SOURCE_AVRO")
        return
    if wire == 8:
        writer.write("SOURCE_ARROW")
        return
    if wire == 9:
        writer.write("SOURCE_BINDING")
        return
    writer.write("SourceType#", Int(wire))


def source_type_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a SourceType value, as a String.

    A thin `String`-collecting wrapper over
    `write_source_type_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_source_type_wire_name(out, wire)
    return out^


# ==========================================================================
# SourceOrientation — engine prefix `SOURCE_KIND_`
# Row vs columnar orientation of a scan. Orthogonal to SourceType.
# SOURCE_KIND_UNSET is 255, which is why the wire numbering is derived
# from the engine value rather than from declaration order.
# Declared in: src/komira_plan_ir/logical_plan.mojo
# ==========================================================================

comptime SOURCE_ORIENTATION_WIRE_MEMBERS: Int = 3
comptime SOURCE_ORIENTATION_ENGINE_MIN: UInt8 = 0
comptime SOURCE_ORIENTATION_ENGINE_MAX: UInt8 = 255
comptime SOURCE_ORIENTATION_WIRE_MIN: Int32 = 1
comptime SOURCE_ORIENTATION_WIRE_MAX: Int32 = 256


def source_orientation_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this SourceOrientation value?

    Runs: [(0, 1), (255, 255)]. Total, never raising.
    """
    return engine_tag <= 1 or engine_tag == 255


def source_orientation_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for SourceOrientation.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not source_orientation_is_declared(engine_tag):
        raise Error("SourceOrientation: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def source_orientation_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for SourceOrientation.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("SourceOrientation: wire value " + String(Int(wire))
            + " is negative; no SourceOrientation value has a negative wire number")
    if wire == 0:
        raise Error("SourceOrientation: wire 0 is SOURCE_KIND_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("SourceOrientation: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not source_orientation_is_declared(engine_tag):
        raise Error("SourceOrientation: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_source_orientation_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a SourceOrientation value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("SOURCE_KIND_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("SOURCE_KIND_COLUMNAR")
        return
    if wire == 2:
        writer.write("SOURCE_KIND_ROW")
        return
    if wire == 256:
        writer.write("SOURCE_KIND_UNSET")
        return
    writer.write("SourceOrientation#", Int(wire))


def source_orientation_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a SourceOrientation value, as a String.

    A thin `String`-collecting wrapper over
    `write_source_orientation_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_source_orientation_wire_name(out, wire)
    return out^


# ==========================================================================
# SourceVariantTag — engine prefix `SOURCE_VARIANT_`
# The closed SourceVariant union's arm tag. Most arms are carried by
# SOURCE_VARIANT_BINDING; the two concrete arms that remain are the EXEMPT
# rows below.
# Declared in: src/komira_scan_source/source_variant.mojo
#
# EXEMPT — declared by the engine and named here, but its wire number
# is RESERVED in plan_vocabulary.proto, so `source_variant_tag_to_wire`
# and `source_variant_tag_from_wire` both refuse it
# (`_source_variant_tag_is_reserved_on_wire`). Neither arm carries a
# `ScanBinding`, so a binding message naming one could only build a
# SourceVariant whose payload is absent. Each row is a debt with a named
# blocker; the row disappears when it is paid.
#   SOURCE_VARIANT_IN_MEMORY: InMemorySource holds `data: ArcPointer[Slab[RecordBatch]]` — LIVE
#     HEAP DATA INSIDE THE IR. A plan carrying this arm is a container
#     of the data, not a description of work, and cannot be written to
#     bytes at all. The row disappears when the arm does
#   SOURCE_VARIANT_PARQUET: ParquetSource carries `_mtime_ns`, an ENVIRONMENT-local filesystem
#     observation that differs across machines, so the arm's identity is
#     not portable as-is. SOURCE_VARIANT_BINDING is the portable
#     replacement and is already the majority arm
# ==========================================================================

comptime SOURCE_VARIANT_TAG_WIRE_MEMBERS: Int = 10
comptime SOURCE_VARIANT_TAG_ENGINE_MIN: UInt8 = 0
comptime SOURCE_VARIANT_TAG_ENGINE_MAX: UInt8 = 9
comptime SOURCE_VARIANT_TAG_WIRE_MIN: Int32 = 1
comptime SOURCE_VARIANT_TAG_WIRE_MAX: Int32 = 10


def source_variant_tag_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this SourceVariantTag value?

    Runs: [(0, 9)]. Total, never raising.
    """
    return engine_tag <= 9


def source_variant_tag_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for SourceVariantTag.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not source_variant_tag_is_declared(engine_tag):
        raise Error("SourceVariantTag: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    if _source_variant_tag_is_reserved_on_wire(engine_tag):
        raise Error("SourceVariantTag: engine tag " + String(Int(engine_tag))
            + " (" + source_variant_tag_wire_name(Int32(Int(engine_tag)) + 1)
            + ") is reserved on the wire: plan_vocabulary.proto keeps it off")
    return Int32(Int(engine_tag)) + 1


def _source_variant_tag_is_reserved_on_wire(engine_tag: UInt8) -> Bool:
    """The EXEMPT rows above: SOURCE_VARIANT_PARQUET (0) and
    SOURCE_VARIANT_IN_MEMORY (1).

    The engine declares both, so `source_variant_tag_is_declared` is true
    for them; plan_vocabulary.proto reserves their wire numbers (1 and 2),
    so neither direction may carry them."""
    return engine_tag == 0 or engine_tag == 1


def source_variant_tag_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for SourceVariantTag.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("SourceVariantTag: wire value " + String(Int(wire))
            + " is negative; no SourceVariantTag value has a negative wire number")
    if wire == 0:
        raise Error("SourceVariantTag: wire 0 is SOURCE_VARIANT_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("SourceVariantTag: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not source_variant_tag_is_declared(engine_tag):
        raise Error("SourceVariantTag: wire value " + String(Int(wire))
            + " is unknown to this reader")
    if _source_variant_tag_is_reserved_on_wire(engine_tag):
        raise Error("SourceVariantTag: wire value " + String(Int(wire)) + " ("
            + source_variant_tag_wire_name(wire)
            + ") is reserved: plan_vocabulary.proto keeps it off the wire")
    return engine_tag


def write_source_variant_tag_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a SourceVariantTag value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("SOURCE_VARIANT_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("SOURCE_VARIANT_PARQUET")
        return
    if wire == 2:
        writer.write("SOURCE_VARIANT_IN_MEMORY")
        return
    if wire == 3:
        writer.write("SOURCE_VARIANT_JSON")
        return
    if wire == 4:
        writer.write("SOURCE_VARIANT_CSV")
        return
    if wire == 5:
        writer.write("SOURCE_VARIANT_ARROW_UNCOMPRESSED")
        return
    if wire == 6:
        writer.write("SOURCE_VARIANT_ARROW_LZ4_FRAME")
        return
    if wire == 7:
        writer.write("SOURCE_VARIANT_ARROW_ZSTD")
        return
    if wire == 8:
        writer.write("SOURCE_VARIANT_ORC")
        return
    if wire == 9:
        writer.write("SOURCE_VARIANT_AVRO")
        return
    if wire == 10:
        writer.write("SOURCE_VARIANT_BINDING")
        return
    writer.write("SourceVariantTag#", Int(wire))


def source_variant_tag_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a SourceVariantTag value, as a String.

    A thin `String`-collecting wrapper over
    `write_source_variant_tag_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_source_variant_tag_wire_name(out, wire)
    return out^


# ==========================================================================
# BinaryOp — engine prefix `BIN_`
# Binary operator. Sparse by design (arithmetic 0-4, comparison 10-15,
# logical 20-21) — PushdownGate.allowed_binary_ops is a bitmask over these
# values.
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime BINARY_OP_WIRE_MEMBERS: Int = 13
comptime BINARY_OP_ENGINE_MIN: UInt8 = 0
comptime BINARY_OP_ENGINE_MAX: UInt8 = 21
comptime BINARY_OP_WIRE_MIN: Int32 = 1
comptime BINARY_OP_WIRE_MAX: Int32 = 22


def binary_op_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this BinaryOp value?

    Runs: [(0, 4), (10, 15), (20, 21)]. Total, never raising.
    """
    return engine_tag <= 4 or (engine_tag >= 10 and engine_tag <= 15) or (engine_tag >= 20 and engine_tag <= 21)


def binary_op_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for BinaryOp.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not binary_op_is_declared(engine_tag):
        raise Error("BinaryOp: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def binary_op_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for BinaryOp.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("BinaryOp: wire value " + String(Int(wire))
            + " is negative; no BinaryOp value has a negative wire number")
    if wire == 0:
        raise Error("BinaryOp: wire 0 is BIN_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("BinaryOp: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not binary_op_is_declared(engine_tag):
        raise Error("BinaryOp: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_binary_op_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a BinaryOp value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("BIN_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("BIN_ADD")
        return
    if wire == 2:
        writer.write("BIN_SUB")
        return
    if wire == 3:
        writer.write("BIN_MUL")
        return
    if wire == 4:
        writer.write("BIN_DIV")
        return
    if wire == 5:
        writer.write("BIN_MOD")
        return
    if wire == 11:
        writer.write("BIN_EQ")
        return
    if wire == 12:
        writer.write("BIN_NE")
        return
    if wire == 13:
        writer.write("BIN_LT")
        return
    if wire == 14:
        writer.write("BIN_LE")
        return
    if wire == 15:
        writer.write("BIN_GT")
        return
    if wire == 16:
        writer.write("BIN_GE")
        return
    if wire == 21:
        writer.write("BIN_AND")
        return
    if wire == 22:
        writer.write("BIN_OR")
        return
    writer.write("BinaryOp#", Int(wire))


def binary_op_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a BinaryOp value, as a String.

    A thin `String`-collecting wrapper over
    `write_binary_op_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_binary_op_wire_name(out, wire)
    return out^


# ==========================================================================
# UnaryOp — engine prefix `UN_`
# Unary operator.
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime UNARY_OP_WIRE_MEMBERS: Int = 9
comptime UNARY_OP_ENGINE_MIN: UInt8 = 0
comptime UNARY_OP_ENGINE_MAX: UInt8 = 8
comptime UNARY_OP_WIRE_MIN: Int32 = 1
comptime UNARY_OP_WIRE_MAX: Int32 = 9


def unary_op_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this UnaryOp value?

    Runs: [(0, 8)]. Total, never raising.
    """
    return engine_tag <= 8


def unary_op_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for UnaryOp.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not unary_op_is_declared(engine_tag):
        raise Error("UnaryOp: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def unary_op_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for UnaryOp.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("UnaryOp: wire value " + String(Int(wire))
            + " is negative; no UnaryOp value has a negative wire number")
    if wire == 0:
        raise Error("UnaryOp: wire 0 is UN_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("UnaryOp: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not unary_op_is_declared(engine_tag):
        raise Error("UnaryOp: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_unary_op_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a UnaryOp value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("UN_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("UN_NOT")
        return
    if wire == 2:
        writer.write("UN_NEGATE")
        return
    if wire == 3:
        writer.write("UN_IS_NULL")
        return
    if wire == 4:
        writer.write("UN_IS_NOT_NULL")
        return
    if wire == 5:
        writer.write("UN_ABS")
        return
    if wire == 6:
        writer.write("UN_SIGN")
        return
    if wire == 7:
        writer.write("UN_TRUNC")
        return
    if wire == 8:
        writer.write("UN_ROUND")
        return
    if wire == 9:
        writer.write("UN_BIT_COUNT")
        return
    writer.write("UnaryOp#", Int(wire))


def unary_op_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a UnaryOp value, as a String.

    A thin `String`-collecting wrapper over
    `write_unary_op_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_unary_op_wire_name(out, wire)
    return out^


# ==========================================================================
# StringOp — engine prefix `STR_`
# String predicate operator.
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime STRING_OP_WIRE_MEMBERS: Int = 4
comptime STRING_OP_ENGINE_MIN: UInt8 = 0
comptime STRING_OP_ENGINE_MAX: UInt8 = 3
comptime STRING_OP_WIRE_MIN: Int32 = 1
comptime STRING_OP_WIRE_MAX: Int32 = 4


def string_op_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this StringOp value?

    Runs: [(0, 3)]. Total, never raising.
    """
    return engine_tag <= 3


def string_op_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for StringOp.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not string_op_is_declared(engine_tag):
        raise Error("StringOp: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def string_op_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for StringOp.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("StringOp: wire value " + String(Int(wire))
            + " is negative; no StringOp value has a negative wire number")
    if wire == 0:
        raise Error("StringOp: wire 0 is STR_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("StringOp: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not string_op_is_declared(engine_tag):
        raise Error("StringOp: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_string_op_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a StringOp value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("STR_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("STR_CONTAINS")
        return
    if wire == 2:
        writer.write("STR_STARTS_WITH")
        return
    if wire == 3:
        writer.write("STR_ENDS_WITH")
        return
    if wire == 4:
        writer.write("STR_LIKE")
        return
    writer.write("StringOp#", Int(wire))


def string_op_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a StringOp value, as a String.

    A thin `String`-collecting wrapper over
    `write_string_op_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_string_op_wire_name(out, wire)
    return out^


# ==========================================================================
# StringFn — engine prefix `STRFN_`
# Unary scalar string function (EXPR_STRING_FN).
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime STRING_FN_WIRE_MEMBERS: Int = 19
comptime STRING_FN_ENGINE_MIN: UInt8 = 0
comptime STRING_FN_ENGINE_MAX: UInt8 = 18
comptime STRING_FN_WIRE_MIN: Int32 = 1
comptime STRING_FN_WIRE_MAX: Int32 = 19


def string_fn_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this StringFn value?

    Runs: [(0, 18)]. Total, never raising.
    """
    return engine_tag <= 18


def string_fn_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for StringFn.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not string_fn_is_declared(engine_tag):
        raise Error("StringFn: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def string_fn_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for StringFn.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("StringFn: wire value " + String(Int(wire))
            + " is negative; no StringFn value has a negative wire number")
    if wire == 0:
        raise Error("StringFn: wire 0 is STRFN_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("StringFn: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not string_fn_is_declared(engine_tag):
        raise Error("StringFn: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_string_fn_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a StringFn value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("STRFN_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("STRFN_UPPER")
        return
    if wire == 2:
        writer.write("STRFN_LOWER")
        return
    if wire == 3:
        writer.write("STRFN_TRIM")
        return
    if wire == 4:
        writer.write("STRFN_LTRIM")
        return
    if wire == 5:
        writer.write("STRFN_RTRIM")
        return
    if wire == 6:
        writer.write("STRFN_LENGTH")
        return
    if wire == 7:
        writer.write("STRFN_REVERSE")
        return
    if wire == 8:
        writer.write("STRFN_ASCII")
        return
    if wire == 9:
        writer.write("STRFN_UNICODE")
        return
    if wire == 10:
        writer.write("STRFN_STRLEN")
        return
    if wire == 11:
        writer.write("STRFN_BIT_LENGTH")
        return
    if wire == 12:
        writer.write("STRFN_HEX")
        return
    if wire == 13:
        writer.write("STRFN_BIN")
        return
    if wire == 14:
        writer.write("STRFN_URL_ENCODE")
        return
    if wire == 15:
        writer.write("STRFN_URL_DECODE")
        return
    if wire == 16:
        writer.write("STRFN_REGEXP_ESCAPE")
        return
    if wire == 17:
        writer.write("STRFN_MD5")
        return
    if wire == 18:
        writer.write("STRFN_SHA1")
        return
    if wire == 19:
        writer.write("STRFN_SHA256")
        return
    writer.write("StringFn#", Int(wire))


def string_fn_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a StringFn value, as a String.

    A thin `String`-collecting wrapper over
    `write_string_fn_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_string_fn_wire_name(out, wire)
    return out^


# ==========================================================================
# StringFnN — engine prefix `STRFNN_`
# Multi-argument scalar string function (EXPR_STRING_FN_N).
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime STRING_FN_N_WIRE_MEMBERS: Int = 14
comptime STRING_FN_N_ENGINE_MIN: UInt8 = 0
comptime STRING_FN_N_ENGINE_MAX: UInt8 = 13
comptime STRING_FN_N_WIRE_MIN: Int32 = 1
comptime STRING_FN_N_WIRE_MAX: Int32 = 14


def string_fn_n_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this StringFnN value?

    Runs: [(0, 13)]. Total, never raising.
    """
    return engine_tag <= 13


def string_fn_n_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for StringFnN.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not string_fn_n_is_declared(engine_tag):
        raise Error("StringFnN: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def string_fn_n_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for StringFnN.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("StringFnN: wire value " + String(Int(wire))
            + " is negative; no StringFnN value has a negative wire number")
    if wire == 0:
        raise Error("StringFnN: wire 0 is STRFNN_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("StringFnN: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not string_fn_n_is_declared(engine_tag):
        raise Error("StringFnN: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_string_fn_n_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a StringFnN value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("STRFNN_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("STRFNN_CONCAT")
        return
    if wire == 2:
        writer.write("STRFNN_CONCAT_WS")
        return
    if wire == 3:
        writer.write("STRFNN_REPLACE")
        return
    if wire == 4:
        writer.write("STRFNN_LPAD")
        return
    if wire == 5:
        writer.write("STRFNN_RPAD")
        return
    if wire == 6:
        writer.write("STRFNN_REPEAT")
        return
    if wire == 7:
        writer.write("STRFNN_STRPOS")
        return
    if wire == 8:
        writer.write("STRFNN_LEVENSHTEIN")
        return
    if wire == 9:
        writer.write("STRFNN_DAMERAU_LEVENSHTEIN")
        return
    if wire == 10:
        writer.write("STRFNN_HAMMING")
        return
    if wire == 11:
        writer.write("STRFNN_TRANSLATE")
        return
    if wire == 12:
        writer.write("STRFNN_JARO")
        return
    if wire == 13:
        writer.write("STRFNN_JARO_WINKLER")
        return
    if wire == 14:
        writer.write("STRFNN_JACCARD")
        return
    writer.write("StringFnN#", Int(wire))


def string_fn_n_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a StringFnN value, as a String.

    A thin `String`-collecting wrapper over
    `write_string_fn_n_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_string_fn_n_wire_name(out, wire)
    return out^


# ==========================================================================
# ColSide — engine prefix `COL_SIDE_`
# Which join input a column reference is qualified to.
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime COL_SIDE_WIRE_MEMBERS: Int = 3
comptime COL_SIDE_ENGINE_MIN: UInt8 = 0
comptime COL_SIDE_ENGINE_MAX: UInt8 = 2
comptime COL_SIDE_WIRE_MIN: Int32 = 1
comptime COL_SIDE_WIRE_MAX: Int32 = 3


def col_side_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this ColSide value?

    Runs: [(0, 2)]. Total, never raising.
    """
    return engine_tag <= 2


def col_side_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for ColSide.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not col_side_is_declared(engine_tag):
        raise Error("ColSide: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def col_side_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for ColSide.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("ColSide: wire value " + String(Int(wire))
            + " is negative; no ColSide value has a negative wire number")
    if wire == 0:
        raise Error("ColSide: wire 0 is COL_SIDE_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("ColSide: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not col_side_is_declared(engine_tag):
        raise Error("ColSide: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_col_side_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a ColSide value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("COL_SIDE_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("COL_SIDE_NONE")
        return
    if wire == 2:
        writer.write("COL_SIDE_LEFT")
        return
    if wire == 3:
        writer.write("COL_SIDE_RIGHT")
        return
    writer.write("ColSide#", Int(wire))


def col_side_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a ColSide value, as a String.

    A thin `String`-collecting wrapper over
    `write_col_side_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_col_side_wire_name(out, wire)
    return out^


# ==========================================================================
# MathFn1 — engine prefix `MATH_`
# Unary math function (EXPR_MATH_FN).
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime MATH_FN1_WIRE_MEMBERS: Int = 24
comptime MATH_FN1_ENGINE_MIN: UInt8 = 0
comptime MATH_FN1_ENGINE_MAX: UInt8 = 23
comptime MATH_FN1_WIRE_MIN: Int32 = 1
comptime MATH_FN1_WIRE_MAX: Int32 = 24


def math_fn1_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this MathFn1 value?

    Runs: [(0, 23)]. Total, never raising.
    """
    return engine_tag <= 23


def math_fn1_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for MathFn1.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not math_fn1_is_declared(engine_tag):
        raise Error("MathFn1: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def math_fn1_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for MathFn1.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("MathFn1: wire value " + String(Int(wire))
            + " is negative; no MathFn1 value has a negative wire number")
    if wire == 0:
        raise Error("MathFn1: wire 0 is MATH_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("MathFn1: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not math_fn1_is_declared(engine_tag):
        raise Error("MathFn1: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_math_fn1_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a MathFn1 value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("MATH_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("MATH_SIN")
        return
    if wire == 2:
        writer.write("MATH_COS")
        return
    if wire == 3:
        writer.write("MATH_SQRT")
        return
    if wire == 4:
        writer.write("MATH_ASIN")
        return
    if wire == 5:
        writer.write("MATH_RADIANS")
        return
    if wire == 6:
        writer.write("MATH_CEIL")
        return
    if wire == 7:
        writer.write("MATH_FLOOR")
        return
    if wire == 8:
        writer.write("MATH_LN")
        return
    if wire == 9:
        writer.write("MATH_EXP")
        return
    if wire == 10:
        writer.write("MATH_LOG10")
        return
    if wire == 11:
        writer.write("MATH_LOG2")
        return
    if wire == 12:
        writer.write("MATH_TAN")
        return
    if wire == 13:
        writer.write("MATH_ATAN")
        return
    if wire == 14:
        writer.write("MATH_ACOS")
        return
    if wire == 15:
        writer.write("MATH_COT")
        return
    if wire == 16:
        writer.write("MATH_DEGREES")
        return
    if wire == 17:
        writer.write("MATH_CBRT")
        return
    if wire == 18:
        writer.write("MATH_SINH")
        return
    if wire == 19:
        writer.write("MATH_COSH")
        return
    if wire == 20:
        writer.write("MATH_TANH")
        return
    if wire == 21:
        writer.write("MATH_ACOSH")
        return
    if wire == 22:
        writer.write("MATH_ASINH")
        return
    if wire == 23:
        writer.write("MATH_ATANH")
        return
    if wire == 24:
        writer.write("MATH_GAMMA")
        return
    writer.write("MathFn1#", Int(wire))


def math_fn1_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a MathFn1 value, as a String.

    A thin `String`-collecting wrapper over
    `write_math_fn1_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_math_fn1_wire_name(out, wire)
    return out^


# ==========================================================================
# MathFn2 — engine prefix `MATH2_`
# Binary math function (EXPR_MATH_FN2).
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime MATH_FN2_WIRE_MEMBERS: Int = 2
comptime MATH_FN2_ENGINE_MIN: UInt8 = 0
comptime MATH_FN2_ENGINE_MAX: UInt8 = 1
comptime MATH_FN2_WIRE_MIN: Int32 = 1
comptime MATH_FN2_WIRE_MAX: Int32 = 2


def math_fn2_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this MathFn2 value?

    Runs: [(0, 1)]. Total, never raising.
    """
    return engine_tag <= 1


def math_fn2_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for MathFn2.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not math_fn2_is_declared(engine_tag):
        raise Error("MathFn2: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def math_fn2_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for MathFn2.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("MathFn2: wire value " + String(Int(wire))
            + " is negative; no MathFn2 value has a negative wire number")
    if wire == 0:
        raise Error("MathFn2: wire 0 is MATH2_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("MathFn2: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not math_fn2_is_declared(engine_tag):
        raise Error("MathFn2: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_math_fn2_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a MathFn2 value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("MATH2_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("MATH2_ATAN2")
        return
    if wire == 2:
        writer.write("MATH2_POW")
        return
    writer.write("MathFn2#", Int(wire))


def math_fn2_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a MathFn2 value, as a String.

    A thin `String`-collecting wrapper over
    `write_math_fn2_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_math_fn2_wire_name(out, wire)
    return out^


# ==========================================================================
# ExtractField — engine prefix `EXTRACT_`
# Temporal field extraction / truncation unit. Sparse: extraction 0-9,
# truncation 16-25 — 10..15 is a RESERVED HOLE, and the membership test
# consults this vocabulary rather than range-checking so a unit landing in
# it is REFUSED at encode.
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime EXTRACT_FIELD_WIRE_MEMBERS: Int = 25
comptime EXTRACT_FIELD_ENGINE_MIN: UInt8 = 0
comptime EXTRACT_FIELD_ENGINE_MAX: UInt8 = 25
comptime EXTRACT_FIELD_WIRE_MIN: Int32 = 1
comptime EXTRACT_FIELD_WIRE_MAX: Int32 = 26


def extract_field_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this ExtractField value?

    Runs: [(0, 14), (16, 25)]. Total, never raising.
    """
    return engine_tag <= 14 or (engine_tag >= 16 and engine_tag <= 25)


def extract_field_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for ExtractField.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not extract_field_is_declared(engine_tag):
        raise Error("ExtractField: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def extract_field_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for ExtractField.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("ExtractField: wire value " + String(Int(wire))
            + " is negative; no ExtractField value has a negative wire number")
    if wire == 0:
        raise Error("ExtractField: wire 0 is EXTRACT_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("ExtractField: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not extract_field_is_declared(engine_tag):
        raise Error("ExtractField: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_extract_field_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a ExtractField value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("EXTRACT_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("EXTRACT_YEAR")
        return
    if wire == 2:
        writer.write("EXTRACT_QUARTER")
        return
    if wire == 3:
        writer.write("EXTRACT_MONTH")
        return
    if wire == 4:
        writer.write("EXTRACT_DAY")
        return
    if wire == 5:
        writer.write("EXTRACT_HOUR")
        return
    if wire == 6:
        writer.write("EXTRACT_MINUTE")
        return
    if wire == 7:
        writer.write("EXTRACT_SECOND")
        return
    if wire == 8:
        writer.write("EXTRACT_DAYOFWEEK")
        return
    if wire == 9:
        writer.write("EXTRACT_ISODOW")
        return
    if wire == 10:
        writer.write("EXTRACT_DAYOFYEAR")
        return
    if wire == 11:
        writer.write("EXTRACT_WEEK")
        return
    if wire == 12:
        writer.write("EXTRACT_ISOYEAR")
        return
    if wire == 13:
        writer.write("EXTRACT_YEARWEEK")
        return
    if wire == 14:
        writer.write("EXTRACT_MILLISECOND")
        return
    if wire == 15:
        writer.write("EXTRACT_MICROSECOND")
        return
    if wire == 17:
        writer.write("EXTRACT_TRUNC_YEAR")
        return
    if wire == 18:
        writer.write("EXTRACT_TRUNC_QUARTER")
        return
    if wire == 19:
        writer.write("EXTRACT_TRUNC_MONTH")
        return
    if wire == 20:
        writer.write("EXTRACT_TRUNC_WEEK")
        return
    if wire == 21:
        writer.write("EXTRACT_TRUNC_DAY")
        return
    if wire == 22:
        writer.write("EXTRACT_TRUNC_HOUR")
        return
    if wire == 23:
        writer.write("EXTRACT_TRUNC_MINUTE")
        return
    if wire == 24:
        writer.write("EXTRACT_TRUNC_SECOND")
        return
    if wire == 25:
        writer.write("EXTRACT_TRUNC_MILLISECOND")
        return
    if wire == 26:
        writer.write("EXTRACT_TRUNC_MICROSECOND")
        return
    writer.write("ExtractField#", Int(wire))


def extract_field_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a ExtractField value, as a String.

    A thin `String`-collecting wrapper over
    `write_extract_field_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_extract_field_wire_name(out, wire)
    return out^


# ==========================================================================
# RegexpOp — engine prefix `REGEXP_`
# Regular-expression operation.
# Declared in: src/komira_plan_expr/expr.mojo
# ==========================================================================

comptime REGEXP_OP_WIRE_MEMBERS: Int = 10
comptime REGEXP_OP_ENGINE_MIN: UInt8 = 0
comptime REGEXP_OP_ENGINE_MAX: UInt8 = 9
comptime REGEXP_OP_WIRE_MIN: Int32 = 1
comptime REGEXP_OP_WIRE_MAX: Int32 = 10


def regexp_op_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this RegexpOp value?

    Runs: [(0, 9)]. Total, never raising.
    """
    return engine_tag <= 9


def regexp_op_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for RegexpOp.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not regexp_op_is_declared(engine_tag):
        raise Error("RegexpOp: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def regexp_op_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for RegexpOp.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("RegexpOp: wire value " + String(Int(wire))
            + " is negative; no RegexpOp value has a negative wire number")
    if wire == 0:
        raise Error("RegexpOp: wire 0 is REGEXP_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("RegexpOp: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not regexp_op_is_declared(engine_tag):
        raise Error("RegexpOp: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_regexp_op_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a RegexpOp value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("REGEXP_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("REGEXP_LIKE")
        return
    if wire == 2:
        writer.write("REGEXP_MATCH")
        return
    if wire == 3:
        writer.write("REGEXP_REPLACE")
        return
    if wire == 4:
        writer.write("REGEXP_EXTRACT")
        return
    if wire == 5:
        writer.write("REGEXP_SPLIT_TO_ARRAY")
        return
    if wire == 6:
        writer.write("REGEXP_EXTRACT_ALL")
        return
    if wire == 7:
        writer.write("REGEXP_COUNT")
        return
    if wire == 8:
        writer.write("REGEXP_INSTR")
        return
    if wire == 9:
        writer.write("REGEXP_SUBSTR")
        return
    if wire == 10:
        writer.write("REGEXP_FULL_MATCH")
        return
    writer.write("RegexpOp#", Int(wire))


def regexp_op_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a RegexpOp value, as a String.

    A thin `String`-collecting wrapper over
    `write_regexp_op_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_regexp_op_wire_name(out, wire)
    return out^


# ==========================================================================
# ArrowType — engine prefix ``
# THE SPACE LEG 2 OF THE ROUND TRIP COMPARES. `Field.arrow_type` is on
# every column of every plan's output schema, so a type the wire cannot
# NAME is a schema that silently differs. ⚠ THE WIRE FIELD DOES NOT CARRY
# THIS ENUM'S NUMBERING: `WireField.arrow_type_id` in plan.proto is a
# uint32 holding `ArrowType.type_id` VERBATIM, because the space is a bare
# UInt8 on the engine and its presence is structural rather than
# sentinel-carried. This enum is the DERIVED MEMBERSHIP REGISTER — the set
# of type_ids a decoder may accept, and the names a non-Mojo frontend
# validates against. Use `arrow_type_is_declared(type_id)`, NOT
# `arrow_type_from_wire`, when checking a decoded `arrow_type_id`.
# Declared in: src/komira_arrow/arrow_types.mojo
# ==========================================================================

comptime ARROW_TYPE_WIRE_MEMBERS: Int = 50
comptime ARROW_TYPE_ENGINE_MIN: UInt8 = 0
comptime ARROW_TYPE_ENGINE_MAX: UInt8 = 49
comptime ARROW_TYPE_WIRE_MIN: Int32 = 1
comptime ARROW_TYPE_WIRE_MAX: Int32 = 50


def arrow_type_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this ArrowType value?

    Runs: [(0, 49)]. Total, never raising.
    """
    return engine_tag <= 49


def arrow_type_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for ArrowType.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not arrow_type_is_declared(engine_tag):
        raise Error("ArrowType: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def arrow_type_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for ArrowType.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("ArrowType: wire value " + String(Int(wire))
            + " is negative; no ArrowType value has a negative wire number")
    if wire == 0:
        raise Error("ArrowType: wire 0 is ARROW_TYPE_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("ArrowType: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not arrow_type_is_declared(engine_tag):
        raise Error("ArrowType: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_arrow_type_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a ArrowType value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("ARROW_TYPE_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("ARROW_TYPE_NULL")
        return
    if wire == 2:
        writer.write("ARROW_TYPE_BOOL")
        return
    if wire == 3:
        writer.write("ARROW_TYPE_INT8")
        return
    if wire == 4:
        writer.write("ARROW_TYPE_INT16")
        return
    if wire == 5:
        writer.write("ARROW_TYPE_INT32")
        return
    if wire == 6:
        writer.write("ARROW_TYPE_INT64")
        return
    if wire == 7:
        writer.write("ARROW_TYPE_UINT8")
        return
    if wire == 8:
        writer.write("ARROW_TYPE_UINT16")
        return
    if wire == 9:
        writer.write("ARROW_TYPE_UINT32")
        return
    if wire == 10:
        writer.write("ARROW_TYPE_UINT64")
        return
    if wire == 11:
        writer.write("ARROW_TYPE_FLOAT16")
        return
    if wire == 12:
        writer.write("ARROW_TYPE_FLOAT32")
        return
    if wire == 13:
        writer.write("ARROW_TYPE_FLOAT64")
        return
    if wire == 14:
        writer.write("ARROW_TYPE_STRING")
        return
    if wire == 15:
        writer.write("ARROW_TYPE_BINARY")
        return
    if wire == 16:
        writer.write("ARROW_TYPE_DATE32")
        return
    if wire == 17:
        writer.write("ARROW_TYPE_DATE64")
        return
    if wire == 18:
        writer.write("ARROW_TYPE_TIMESTAMP")
        return
    if wire == 19:
        writer.write("ARROW_TYPE_DECIMAL128")
        return
    if wire == 20:
        writer.write("ARROW_TYPE_DICTIONARY")
        return
    if wire == 21:
        writer.write("ARROW_TYPE_LIST")
        return
    if wire == 22:
        writer.write("ARROW_TYPE_STRUCT")
        return
    if wire == 23:
        writer.write("ARROW_TYPE_TIMESTAMP_S")
        return
    if wire == 24:
        writer.write("ARROW_TYPE_TIMESTAMP_MS")
        return
    if wire == 25:
        writer.write("ARROW_TYPE_TIMESTAMP_US")
        return
    if wire == 26:
        writer.write("ARROW_TYPE_TIMESTAMP_NS")
        return
    if wire == 27:
        writer.write("ARROW_TYPE_LARGE_STRING")
        return
    if wire == 28:
        writer.write("ARROW_TYPE_LARGE_BINARY")
        return
    if wire == 29:
        writer.write("ARROW_TYPE_MAP")
        return
    if wire == 30:
        writer.write("ARROW_TYPE_DECIMAL256")
        return
    if wire == 31:
        writer.write("ARROW_TYPE_TIME32_S")
        return
    if wire == 32:
        writer.write("ARROW_TYPE_TIME32_MS")
        return
    if wire == 33:
        writer.write("ARROW_TYPE_TIME64_US")
        return
    if wire == 34:
        writer.write("ARROW_TYPE_TIME64_NS")
        return
    if wire == 35:
        writer.write("ARROW_TYPE_DURATION_S")
        return
    if wire == 36:
        writer.write("ARROW_TYPE_DURATION_MS")
        return
    if wire == 37:
        writer.write("ARROW_TYPE_DURATION_US")
        return
    if wire == 38:
        writer.write("ARROW_TYPE_DURATION_NS")
        return
    if wire == 39:
        writer.write("ARROW_TYPE_INTERVAL_YEAR_MONTH")
        return
    if wire == 40:
        writer.write("ARROW_TYPE_INTERVAL_DAY_TIME")
        return
    if wire == 41:
        writer.write("ARROW_TYPE_INTERVAL_MONTH_DAY_NANO")
        return
    if wire == 42:
        writer.write("ARROW_TYPE_UNION_SPARSE")
        return
    if wire == 43:
        writer.write("ARROW_TYPE_UNION_DENSE")
        return
    if wire == 44:
        writer.write("ARROW_TYPE_LARGE_LIST")
        return
    if wire == 45:
        writer.write("ARROW_TYPE_FIXED_SIZE_BINARY")
        return
    if wire == 46:
        writer.write("ARROW_TYPE_FIXED_SIZE_LIST")
        return
    if wire == 47:
        writer.write("ARROW_TYPE_BINARY_VIEW")
        return
    if wire == 48:
        writer.write("ARROW_TYPE_UTF8_VIEW")
        return
    if wire == 49:
        writer.write("ARROW_TYPE_LIST_VIEW")
        return
    if wire == 50:
        writer.write("ARROW_TYPE_LARGE_LIST_VIEW")
        return
    writer.write("ArrowType#", Int(wire))


def arrow_type_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a ArrowType value, as a String.

    A thin `String`-collecting wrapper over
    `write_arrow_type_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_arrow_type_wire_name(out, wire)
    return out^


# ==========================================================================
# WriteFormat — engine prefix `WFMT_`
# `WireWriteTarget.format` — the file format a write envelope asks for.
# Three members, one per SDK file sink family (parquet / csv / jsonl;
# DuckDB spells the third `FORMAT 'json'`). ⚠ A DECODER MUST NOT STOP AT
# THIS SPACE: validity is a property of the (format, compression) PAIR,
# and `write_target_supported` in the same file is the one table that
# decides it. Snappy is parquet-only, so (WFMT_CSV, WCOMP_SNAPPY) is two
# valid members and no sink.
# Declared in: src/komira_arrow/write_target.mojo
# ==========================================================================

comptime WRITE_FORMAT_WIRE_MEMBERS: Int = 3
comptime WRITE_FORMAT_ENGINE_MIN: UInt8 = 0
comptime WRITE_FORMAT_ENGINE_MAX: UInt8 = 2
comptime WRITE_FORMAT_WIRE_MIN: Int32 = 1
comptime WRITE_FORMAT_WIRE_MAX: Int32 = 3


def write_format_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this WriteFormat value?

    Runs: [(0, 2)]. Total, never raising.
    """
    return engine_tag <= 2


def write_format_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for WriteFormat.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not write_format_is_declared(engine_tag):
        raise Error("WriteFormat: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def write_format_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for WriteFormat.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("WriteFormat: wire value " + String(Int(wire))
            + " is negative; no WriteFormat value has a negative wire number")
    if wire == 0:
        raise Error("WriteFormat: wire 0 is WFMT_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("WriteFormat: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not write_format_is_declared(engine_tag):
        raise Error("WriteFormat: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_write_format_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a WriteFormat value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("WFMT_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("WFMT_PARQUET")
        return
    if wire == 2:
        writer.write("WFMT_CSV")
        return
    if wire == 3:
        writer.write("WFMT_JSONL")
        return
    writer.write("WriteFormat#", Int(wire))


def write_format_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a WriteFormat value, as a String.

    A thin `String`-collecting wrapper over
    `write_write_format_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_write_format_wire_name(out, wire)
    return out^


# ==========================================================================
# WriteCompression — engine prefix `WCOMP_`
# `WireWriteTarget.codec` — the compression a write envelope asks for. ⚠ A
# WRONG VALUE HERE IS A WRONG FILE, NOT A DECODE FAILURE: the destination
# path is carried verbatim beside it, so a codec that decoded as GZIP
# where the producer meant ZSTD puts the other codec's bytes at a path
# named for this one — invisible to a row count and to a wall clock alike,
# which is the hazard `plan_write._sink_tag_for`'s own docstring names.
# That is why the codec crosses as a validated enum rather than as a bare
# uint32.
# Declared in: src/komira_arrow/write_target.mojo
# ==========================================================================

comptime WRITE_COMPRESSION_WIRE_MEMBERS: Int = 5
comptime WRITE_COMPRESSION_ENGINE_MIN: UInt8 = 0
comptime WRITE_COMPRESSION_ENGINE_MAX: UInt8 = 4
comptime WRITE_COMPRESSION_WIRE_MIN: Int32 = 1
comptime WRITE_COMPRESSION_WIRE_MAX: Int32 = 5


def write_compression_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this WriteCompression value?

    Runs: [(0, 4)]. Total, never raising.
    """
    return engine_tag <= 4


def write_compression_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for WriteCompression.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not write_compression_is_declared(engine_tag):
        raise Error("WriteCompression: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def write_compression_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for WriteCompression.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("WriteCompression: wire value " + String(Int(wire))
            + " is negative; no WriteCompression value has a negative wire number")
    if wire == 0:
        raise Error("WriteCompression: wire 0 is WCOMP_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("WriteCompression: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not write_compression_is_declared(engine_tag):
        raise Error("WriteCompression: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_write_compression_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a WriteCompression value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("WCOMP_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("WCOMP_SNAPPY")
        return
    if wire == 2:
        writer.write("WCOMP_UNCOMPRESSED")
        return
    if wire == 3:
        writer.write("WCOMP_ZSTD")
        return
    if wire == 4:
        writer.write("WCOMP_GZIP")
        return
    if wire == 5:
        writer.write("WCOMP_LZ4")
        return
    writer.write("WriteCompression#", Int(wire))


def write_compression_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a WriteCompression value, as a String.

    A thin `String`-collecting wrapper over
    `write_write_compression_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_write_compression_wire_name(out, wire)
    return out^


# ==========================================================================
# ScalarKind — engine prefix `SCALAR_KIND_`
# ★ A DISCRIMINATOR.
# `ScalarValue._kind` selects which of the struct's payload fields is
# live, so a decoder that accepts an out-of-range kind produces a scalar
# that reads a field nothing wrote — an unvalidated tag beside flat
# payload. ⚠ NOT A TOTAL UNION ON ITS OWN: kind 0 (`SCALAR_KIND_DTYPE`)
# means `use the dtype field`, so the live arm is the PAIR (kind, dtype)
# and no proto `oneof` over kind alone can express it.
# Declared in: src/komira_plan_expr/scalar_value.mojo
# ==========================================================================

comptime SCALAR_KIND_WIRE_MEMBERS: Int = 10
comptime SCALAR_KIND_ENGINE_MIN: UInt8 = 0
comptime SCALAR_KIND_ENGINE_MAX: UInt8 = 9
comptime SCALAR_KIND_WIRE_MIN: Int32 = 1
comptime SCALAR_KIND_WIRE_MAX: Int32 = 10


def scalar_kind_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this ScalarKind value?

    Runs: [(0, 9)]. Total, never raising.
    """
    return engine_tag <= 9


def scalar_kind_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for ScalarKind.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not scalar_kind_is_declared(engine_tag):
        raise Error("ScalarKind: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def scalar_kind_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for ScalarKind.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("ScalarKind: wire value " + String(Int(wire))
            + " is negative; no ScalarKind value has a negative wire number")
    if wire == 0:
        raise Error("ScalarKind: wire 0 is SCALAR_KIND_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("ScalarKind: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not scalar_kind_is_declared(engine_tag):
        raise Error("ScalarKind: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_scalar_kind_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a ScalarKind value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("SCALAR_KIND_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("SCALAR_KIND_DTYPE")
        return
    if wire == 2:
        writer.write("SCALAR_KIND_DECIMAL128")
        return
    if wire == 3:
        writer.write("SCALAR_KIND_DATE32")
        return
    if wire == 4:
        writer.write("SCALAR_KIND_TIMESTAMP")
        return
    if wire == 5:
        writer.write("SCALAR_KIND_STRING")
        return
    if wire == 6:
        writer.write("SCALAR_KIND_INTERVAL")
        return
    if wire == 7:
        writer.write("SCALAR_KIND_TIME")
        return
    if wire == 8:
        writer.write("SCALAR_KIND_DURATION")
        return
    if wire == 9:
        writer.write("SCALAR_KIND_DECIMAL256")
        return
    if wire == 10:
        writer.write("SCALAR_KIND_BINARY")
        return
    writer.write("ScalarKind#", Int(wire))


def scalar_kind_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a ScalarKind value, as a String.

    A thin `String`-collecting wrapper over
    `write_scalar_kind_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_scalar_kind_wire_name(out, wire)
    return out^


# ==========================================================================
# ScalarTimeUnit — engine prefix `SCALAR_TIME_UNIT_`
# Arrow time unit for a TIME / DURATION scalar. Read together with
# `int_val`, so a wrong unit is a silently wrong VALUE (a nanosecond
# duration read as seconds) rather than a decode failure.
# Declared in: src/komira_plan_expr/scalar_value.mojo
# ==========================================================================

comptime SCALAR_TIME_UNIT_WIRE_MEMBERS: Int = 4
comptime SCALAR_TIME_UNIT_ENGINE_MIN: UInt8 = 0
comptime SCALAR_TIME_UNIT_ENGINE_MAX: UInt8 = 3
comptime SCALAR_TIME_UNIT_WIRE_MIN: Int32 = 1
comptime SCALAR_TIME_UNIT_WIRE_MAX: Int32 = 4


def scalar_time_unit_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this ScalarTimeUnit value?

    Runs: [(0, 3)]. Total, never raising.
    """
    return engine_tag <= 3


def scalar_time_unit_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for ScalarTimeUnit.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not scalar_time_unit_is_declared(engine_tag):
        raise Error("ScalarTimeUnit: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def scalar_time_unit_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for ScalarTimeUnit.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("ScalarTimeUnit: wire value " + String(Int(wire))
            + " is negative; no ScalarTimeUnit value has a negative wire number")
    if wire == 0:
        raise Error("ScalarTimeUnit: wire 0 is SCALAR_TIME_UNIT_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("ScalarTimeUnit: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not scalar_time_unit_is_declared(engine_tag):
        raise Error("ScalarTimeUnit: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_scalar_time_unit_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a ScalarTimeUnit value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("SCALAR_TIME_UNIT_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("SCALAR_TIME_UNIT_SECOND")
        return
    if wire == 2:
        writer.write("SCALAR_TIME_UNIT_MILLI")
        return
    if wire == 3:
        writer.write("SCALAR_TIME_UNIT_MICRO")
        return
    if wire == 4:
        writer.write("SCALAR_TIME_UNIT_NANO")
        return
    writer.write("ScalarTimeUnit#", Int(wire))


def scalar_time_unit_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a ScalarTimeUnit value, as a String.

    A thin `String`-collecting wrapper over
    `write_scalar_time_unit_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_scalar_time_unit_wire_name(out, wire)
    return out^


# ==========================================================================
# ParamTag — engine prefix `PARAM_`
# `ParamValue.tag` — which of a scan parameter's three payload slots is
# live. ⚠ THIS IS A NARROW-BEFORE-VALIDATE SITE: computing
# `UInt8(Int(e.tag))` and THEN comparing would turn a wire tag of 256 into
# 0 and decode it as PARAM_STR — an out-of-range value silently becoming a
# valid one — so the tag is validated before it is narrowed.
# Declared in: src/komira_scan_source/scan_params.mojo
# ==========================================================================

comptime PARAM_TAG_WIRE_MEMBERS: Int = 6
comptime PARAM_TAG_ENGINE_MIN: UInt8 = 0
comptime PARAM_TAG_ENGINE_MAX: UInt8 = 5
comptime PARAM_TAG_WIRE_MIN: Int32 = 1
comptime PARAM_TAG_WIRE_MAX: Int32 = 6


def param_tag_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this ParamTag value?

    Runs: [(0, 5)]. Total, never raising.
    """
    return engine_tag <= 5


def param_tag_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for ParamTag.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not param_tag_is_declared(engine_tag):
        raise Error("ParamTag: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def param_tag_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for ParamTag.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("ParamTag: wire value " + String(Int(wire))
            + " is negative; no ParamTag value has a negative wire number")
    if wire == 0:
        raise Error("ParamTag: wire 0 is PARAM_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("ParamTag: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not param_tag_is_declared(engine_tag):
        raise Error("ParamTag: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_param_tag_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a ParamTag value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("PARAM_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("PARAM_STR")
        return
    if wire == 2:
        writer.write("PARAM_I64")
        return
    if wire == 3:
        writer.write("PARAM_U64")
        return
    if wire == 4:
        writer.write("PARAM_F64")
        return
    if wire == 5:
        writer.write("PARAM_BOOL")
        return
    if wire == 6:
        writer.write("PARAM_BYTES")
        return
    writer.write("ParamTag#", Int(wire))


def param_tag_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a ParamTag value, as a String.

    A thin `String`-collecting wrapper over
    `write_param_tag_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_param_tag_wire_name(out, wire)
    return out^


# ==========================================================================
# PushdownGateMode — engine prefix `GATE_`
# `PushdownGate.mode` — REJECT_ALL / ACCEPT_ALL / SHAPED. ⚠ `GATE_OP_*`
# and `GATE_OPS_COMPARISON` in the same file are EXCLUDED: they are BIT
# POSITIONS in `allowed_binary_ops`, a mask, not an enumeration, and
# folding a mask into a +1-offset enum would make every stored gate mean
# something else. They are declared as `1 << n` so the literal-only regex
# does not see them today — the exclusion is against the day someone
# writes the constant out.
# Declared in: src/komira_scan_source/pushdown_gate.mojo
# ==========================================================================

comptime PUSHDOWN_GATE_MODE_WIRE_MEMBERS: Int = 3
comptime PUSHDOWN_GATE_MODE_ENGINE_MIN: UInt8 = 0
comptime PUSHDOWN_GATE_MODE_ENGINE_MAX: UInt8 = 2
comptime PUSHDOWN_GATE_MODE_WIRE_MIN: Int32 = 1
comptime PUSHDOWN_GATE_MODE_WIRE_MAX: Int32 = 3


def pushdown_gate_mode_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this PushdownGateMode value?

    Runs: [(0, 2)]. Total, never raising.
    """
    return engine_tag <= 2


def pushdown_gate_mode_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for PushdownGateMode.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not pushdown_gate_mode_is_declared(engine_tag):
        raise Error("PushdownGateMode: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def pushdown_gate_mode_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for PushdownGateMode.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("PushdownGateMode: wire value " + String(Int(wire))
            + " is negative; no PushdownGateMode value has a negative wire number")
    if wire == 0:
        raise Error("PushdownGateMode: wire 0 is GATE_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("PushdownGateMode: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not pushdown_gate_mode_is_declared(engine_tag):
        raise Error("PushdownGateMode: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_pushdown_gate_mode_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a PushdownGateMode value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("GATE_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("GATE_REJECT_ALL")
        return
    if wire == 2:
        writer.write("GATE_ACCEPT_ALL")
        return
    if wire == 3:
        writer.write("GATE_SHAPED")
        return
    writer.write("PushdownGateMode#", Int(wire))


def pushdown_gate_mode_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a PushdownGateMode value, as a String.

    A thin `String`-collecting wrapper over
    `write_pushdown_gate_mode_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_pushdown_gate_mode_wire_name(out, wire)
    return out^


# ==========================================================================
# SnapshotPolicy — engine prefix `SNAPSHOT_`
# `ScanBinding.snapshot_policy` — whether `snapshot_token` participates in
# IDENTITY. NONE / PINNED (token IS identity, folded into identity_hash) /
# LIVE (token excluded and re-resolved at execution). One byte that
# decides whether a cached plan may be replayed, so a decoded wrong value
# is a correctness fault in the plan cache, not a decode error.
# Declared in: src/komira_scan_source/scan_binding.mojo
# ==========================================================================

comptime SNAPSHOT_POLICY_WIRE_MEMBERS: Int = 3
comptime SNAPSHOT_POLICY_ENGINE_MIN: UInt8 = 0
comptime SNAPSHOT_POLICY_ENGINE_MAX: UInt8 = 2
comptime SNAPSHOT_POLICY_WIRE_MIN: Int32 = 1
comptime SNAPSHOT_POLICY_WIRE_MAX: Int32 = 3


def snapshot_policy_is_declared(engine_tag: UInt8) -> Bool:
    """Does the engine declare this SnapshotPolicy value?

    Runs: [(0, 2)]. Total, never raising.
    """
    return engine_tag <= 2


def snapshot_policy_to_wire(engine_tag: UInt8) raises -> Int32:
    """Engine tag -> permanent wire number for SnapshotPolicy.

    RAISES on a value the engine does not declare: encoding a tag
    this vocabulary has never heard of would write bytes that no
    reader can name."""
    if not snapshot_policy_is_declared(engine_tag):
        raise Error("SnapshotPolicy: engine tag " + String(Int(engine_tag))
            + " is not in the plan wire vocabulary")
    return Int32(Int(engine_tag)) + 1


def snapshot_policy_from_wire(wire: Int32) raises -> UInt8:
    """Wire number -> engine tag for SnapshotPolicy.

    RAISES on 0 (UNSPECIFIED — which is what an ABSENT proto3 enum
    field decodes to) and on any value this reader does not know.
    Fail loud; never guess a plan node."""
    if wire < 0:
        raise Error("SnapshotPolicy: wire value " + String(Int(wire))
            + " is negative; no SnapshotPolicy value has a negative wire number")
    if wire == 0:
        raise Error("SnapshotPolicy: wire 0 is SNAPSHOT_WIRE_UNSPECIFIED — an absent"
            + " proto3 enum field is not a tag")
    if wire > 256:
        raise Error("SnapshotPolicy: wire value " + String(Int(wire))
            + " is out of range for a UInt8 engine tag")
    var engine_tag = UInt8(Int(wire) - 1)
    if not snapshot_policy_is_declared(engine_tag):
        raise Error("SnapshotPolicy: wire value " + String(Int(wire))
            + " is unknown to this reader")
    return engine_tag


def write_snapshot_policy_wire_name[W: Writer](mut writer: W, wire: Int32):
    """WRITE the stable wire NAME for a SnapshotPolicy value.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner
    at the top of this file. Every arm writes its literal into
    `writer`; no string constant is ever selected and returned, so
    the compiler synthesises no parallel (pointer, length) constant
    arrays for this ladder and there is no pair for a later link to
    cross. Total, never raising: this is the diagnostic path, and a
    diagnostic that raises is one you cannot use inside an error
    handler. An unknown value renders as `<enum>#<n>`."""
    if wire == 0:
        writer.write("SNAPSHOT_WIRE_UNSPECIFIED")
        return
    if wire == 1:
        writer.write("SNAPSHOT_NONE")
        return
    if wire == 2:
        writer.write("SNAPSHOT_PINNED")
        return
    if wire == 3:
        writer.write("SNAPSHOT_LIVE")
        return
    writer.write("SnapshotPolicy#", Int(wire))


def snapshot_policy_wire_name(wire: Int32) -> String:
    """The stable wire NAME for a SnapshotPolicy value, as a String.

    A thin `String`-collecting wrapper over
    `write_snapshot_policy_wire_name`, for the many diagnostic call sites
    that build a message by concatenation and have no `Writer` in
    scope. The LADDER lives in the writing helper — keep it that
    way; moving the arms back in here restores the shape the banner
    describes. Total, never raising.
    """
    var out = String()
    write_snapshot_policy_wire_name(out, wire)
    return out^


# ==========================================================================
# SPACE-INDEXED DISPATCH — one generic codec over all
# 32 spaces, addressed by a stable space index.
#
# The index is an INTERNAL addressing scheme, not a wire value:
# it is derived from the generator's space order and may move if
# a space is inserted. Nothing serializes it. What serializes is
# the per-space wire number, which is permanent.
# ==========================================================================

comptime PLAN_WIRE_SPACE_PLAN_TAG: Int = 0
comptime PLAN_WIRE_SPACE_EXPR_TAG: Int = 1
comptime PLAN_WIRE_SPACE_AGG_FN: Int = 2
comptime PLAN_WIRE_SPACE_WINDOW_FN: Int = 3
comptime PLAN_WIRE_SPACE_FRAME_UNITS: Int = 4
comptime PLAN_WIRE_SPACE_FRAME_BOUND: Int = 5
comptime PLAN_WIRE_SPACE_JOIN_TYPE: Int = 6
comptime PLAN_WIRE_SPACE_JOIN_ALGO: Int = 7
comptime PLAN_WIRE_SPACE_ASOF_DIRECTION: Int = 8
comptime PLAN_WIRE_SPACE_ASOF_TOLERANCE_KIND: Int = 9
comptime PLAN_WIRE_SPACE_CORRELATED_KIND: Int = 10
comptime PLAN_WIRE_SPACE_SOURCE_TYPE: Int = 11
comptime PLAN_WIRE_SPACE_SOURCE_ORIENTATION: Int = 12
comptime PLAN_WIRE_SPACE_SOURCE_VARIANT_TAG: Int = 13
comptime PLAN_WIRE_SPACE_BINARY_OP: Int = 14
comptime PLAN_WIRE_SPACE_UNARY_OP: Int = 15
comptime PLAN_WIRE_SPACE_STRING_OP: Int = 16
comptime PLAN_WIRE_SPACE_STRING_FN: Int = 17
comptime PLAN_WIRE_SPACE_STRING_FN_N: Int = 18
comptime PLAN_WIRE_SPACE_COL_SIDE: Int = 19
comptime PLAN_WIRE_SPACE_MATH_FN1: Int = 20
comptime PLAN_WIRE_SPACE_MATH_FN2: Int = 21
comptime PLAN_WIRE_SPACE_EXTRACT_FIELD: Int = 22
comptime PLAN_WIRE_SPACE_REGEXP_OP: Int = 23
comptime PLAN_WIRE_SPACE_ARROW_TYPE: Int = 24
comptime PLAN_WIRE_SPACE_WRITE_FORMAT: Int = 25
comptime PLAN_WIRE_SPACE_WRITE_COMPRESSION: Int = 26
comptime PLAN_WIRE_SPACE_SCALAR_KIND: Int = 27
comptime PLAN_WIRE_SPACE_SCALAR_TIME_UNIT: Int = 28
comptime PLAN_WIRE_SPACE_PARAM_TAG: Int = 29
comptime PLAN_WIRE_SPACE_PUSHDOWN_GATE_MODE: Int = 30
comptime PLAN_WIRE_SPACE_SNAPSHOT_POLICY: Int = 31


def write_plan_wire_space_name[W: Writer](mut writer: W, space: Int):
    """WRITE the enum type name for a space index.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner at
    the top of this file. Total, never raises.
    """
    if space == 0:
        writer.write("PlanTag")
        return
    if space == 1:
        writer.write("ExprTag")
        return
    if space == 2:
        writer.write("AggFn")
        return
    if space == 3:
        writer.write("WindowFn")
        return
    if space == 4:
        writer.write("FrameUnits")
        return
    if space == 5:
        writer.write("FrameBound")
        return
    if space == 6:
        writer.write("JoinType")
        return
    if space == 7:
        writer.write("JoinAlgo")
        return
    if space == 8:
        writer.write("AsofDirection")
        return
    if space == 9:
        writer.write("AsofToleranceKind")
        return
    if space == 10:
        writer.write("CorrelatedKind")
        return
    if space == 11:
        writer.write("SourceType")
        return
    if space == 12:
        writer.write("SourceOrientation")
        return
    if space == 13:
        writer.write("SourceVariantTag")
        return
    if space == 14:
        writer.write("BinaryOp")
        return
    if space == 15:
        writer.write("UnaryOp")
        return
    if space == 16:
        writer.write("StringOp")
        return
    if space == 17:
        writer.write("StringFn")
        return
    if space == 18:
        writer.write("StringFnN")
        return
    if space == 19:
        writer.write("ColSide")
        return
    if space == 20:
        writer.write("MathFn1")
        return
    if space == 21:
        writer.write("MathFn2")
        return
    if space == 22:
        writer.write("ExtractField")
        return
    if space == 23:
        writer.write("RegexpOp")
        return
    if space == 24:
        writer.write("ArrowType")
        return
    if space == 25:
        writer.write("WriteFormat")
        return
    if space == 26:
        writer.write("WriteCompression")
        return
    if space == 27:
        writer.write("ScalarKind")
        return
    if space == 28:
        writer.write("ScalarTimeUnit")
        return
    if space == 29:
        writer.write("ParamTag")
        return
    if space == 30:
        writer.write("PushdownGateMode")
        return
    if space == 31:
        writer.write("SnapshotPolicy")
        return
    writer.write("PlanWireSpace#", space)


def plan_wire_space_name(space: Int) -> String:
    """The enum type name for a space index, as a String.

    A thin `String`-collecting wrapper over
    `write_plan_wire_space_name`; the LADDER lives there. Total,
    never raises.
    """
    var out = String()
    write_plan_wire_space_name(out, space)
    return out^


def plan_wire_space_member_count(space: Int) raises -> Int:
    """How many members a space publishes. RAISES on a bad index."""
    if space == 0:
        return 16
    if space == 1:
        return 27
    if space == 2:
        return 37
    if space == 3:
        return 16
    if space == 4:
        return 2
    if space == 5:
        return 5
    if space == 6:
        return 7
    if space == 7:
        return 3
    if space == 8:
        return 3
    if space == 9:
        return 3
    if space == 10:
        return 4
    if space == 11:
        return 9
    if space == 12:
        return 3
    if space == 13:
        return 10
    if space == 14:
        return 13
    if space == 15:
        return 9
    if space == 16:
        return 4
    if space == 17:
        return 19
    if space == 18:
        return 14
    if space == 19:
        return 3
    if space == 20:
        return 24
    if space == 21:
        return 2
    if space == 22:
        return 25
    if space == 23:
        return 10
    if space == 24:
        return 50
    if space == 25:
        return 3
    if space == 26:
        return 5
    if space == 27:
        return 10
    if space == 28:
        return 4
    if space == 29:
        return 6
    if space == 30:
        return 3
    if space == 31:
        return 3
    raise Error("plan wire: no such space index " + String(space))


def plan_wire_space_engine_max(space: Int) raises -> UInt8:
    """The highest engine value a space declares."""
    if space == 0:
        return 15
    if space == 1:
        return 26
    if space == 2:
        return 36
    if space == 3:
        return 24
    if space == 4:
        return 1
    if space == 5:
        return 4
    if space == 6:
        return 6
    if space == 7:
        return 2
    if space == 8:
        return 2
    if space == 9:
        return 2
    if space == 10:
        return 3
    if space == 11:
        return 8
    if space == 12:
        return 255
    if space == 13:
        return 9
    if space == 14:
        return 21
    if space == 15:
        return 8
    if space == 16:
        return 3
    if space == 17:
        return 18
    if space == 18:
        return 13
    if space == 19:
        return 2
    if space == 20:
        return 23
    if space == 21:
        return 1
    if space == 22:
        return 25
    if space == 23:
        return 9
    if space == 24:
        return 49
    if space == 25:
        return 2
    if space == 26:
        return 4
    if space == 27:
        return 9
    if space == 28:
        return 3
    if space == 29:
        return 5
    if space == 30:
        return 2
    if space == 31:
        return 2
    raise Error("plan wire: no such space index " + String(space))


def plan_wire_is_declared(space: Int, engine_tag: UInt8) raises -> Bool:
    """Does `space` declare `engine_tag`? RAISES on a bad index.

    Deliberately RAISING rather than returning False for an unknown
    space: a False would make a codec silently skip a field whose
    space it addressed wrongly."""
    if space == 0:
        return plan_tag_is_declared(engine_tag)
    if space == 1:
        return expr_tag_is_declared(engine_tag)
    if space == 2:
        return agg_fn_is_declared(engine_tag)
    if space == 3:
        return window_fn_is_declared(engine_tag)
    if space == 4:
        return frame_units_is_declared(engine_tag)
    if space == 5:
        return frame_bound_is_declared(engine_tag)
    if space == 6:
        return join_type_is_declared(engine_tag)
    if space == 7:
        return join_algo_is_declared(engine_tag)
    if space == 8:
        return asof_direction_is_declared(engine_tag)
    if space == 9:
        return asof_tolerance_kind_is_declared(engine_tag)
    if space == 10:
        return correlated_kind_is_declared(engine_tag)
    if space == 11:
        return source_type_is_declared(engine_tag)
    if space == 12:
        return source_orientation_is_declared(engine_tag)
    if space == 13:
        return source_variant_tag_is_declared(engine_tag)
    if space == 14:
        return binary_op_is_declared(engine_tag)
    if space == 15:
        return unary_op_is_declared(engine_tag)
    if space == 16:
        return string_op_is_declared(engine_tag)
    if space == 17:
        return string_fn_is_declared(engine_tag)
    if space == 18:
        return string_fn_n_is_declared(engine_tag)
    if space == 19:
        return col_side_is_declared(engine_tag)
    if space == 20:
        return math_fn1_is_declared(engine_tag)
    if space == 21:
        return math_fn2_is_declared(engine_tag)
    if space == 22:
        return extract_field_is_declared(engine_tag)
    if space == 23:
        return regexp_op_is_declared(engine_tag)
    if space == 24:
        return arrow_type_is_declared(engine_tag)
    if space == 25:
        return write_format_is_declared(engine_tag)
    if space == 26:
        return write_compression_is_declared(engine_tag)
    if space == 27:
        return scalar_kind_is_declared(engine_tag)
    if space == 28:
        return scalar_time_unit_is_declared(engine_tag)
    if space == 29:
        return param_tag_is_declared(engine_tag)
    if space == 30:
        return pushdown_gate_mode_is_declared(engine_tag)
    if space == 31:
        return snapshot_policy_is_declared(engine_tag)
    raise Error("plan wire: no such space index " + String(space))


def plan_wire_to_wire(space: Int, engine_tag: UInt8) raises -> Int32:
    """Encode an engine tag in `space`. RAISES on either being bad."""
    if space == 0:
        return plan_tag_to_wire(engine_tag)
    if space == 1:
        return expr_tag_to_wire(engine_tag)
    if space == 2:
        return agg_fn_to_wire(engine_tag)
    if space == 3:
        return window_fn_to_wire(engine_tag)
    if space == 4:
        return frame_units_to_wire(engine_tag)
    if space == 5:
        return frame_bound_to_wire(engine_tag)
    if space == 6:
        return join_type_to_wire(engine_tag)
    if space == 7:
        return join_algo_to_wire(engine_tag)
    if space == 8:
        return asof_direction_to_wire(engine_tag)
    if space == 9:
        return asof_tolerance_kind_to_wire(engine_tag)
    if space == 10:
        return correlated_kind_to_wire(engine_tag)
    if space == 11:
        return source_type_to_wire(engine_tag)
    if space == 12:
        return source_orientation_to_wire(engine_tag)
    if space == 13:
        return source_variant_tag_to_wire(engine_tag)
    if space == 14:
        return binary_op_to_wire(engine_tag)
    if space == 15:
        return unary_op_to_wire(engine_tag)
    if space == 16:
        return string_op_to_wire(engine_tag)
    if space == 17:
        return string_fn_to_wire(engine_tag)
    if space == 18:
        return string_fn_n_to_wire(engine_tag)
    if space == 19:
        return col_side_to_wire(engine_tag)
    if space == 20:
        return math_fn1_to_wire(engine_tag)
    if space == 21:
        return math_fn2_to_wire(engine_tag)
    if space == 22:
        return extract_field_to_wire(engine_tag)
    if space == 23:
        return regexp_op_to_wire(engine_tag)
    if space == 24:
        return arrow_type_to_wire(engine_tag)
    if space == 25:
        return write_format_to_wire(engine_tag)
    if space == 26:
        return write_compression_to_wire(engine_tag)
    if space == 27:
        return scalar_kind_to_wire(engine_tag)
    if space == 28:
        return scalar_time_unit_to_wire(engine_tag)
    if space == 29:
        return param_tag_to_wire(engine_tag)
    if space == 30:
        return pushdown_gate_mode_to_wire(engine_tag)
    if space == 31:
        return snapshot_policy_to_wire(engine_tag)
    raise Error("plan wire: no such space index " + String(space))


def plan_wire_from_wire(space: Int, wire: Int32) raises -> UInt8:
    """Decode a wire number in `space`. RAISES on either being bad."""
    if space == 0:
        return plan_tag_from_wire(wire)
    if space == 1:
        return expr_tag_from_wire(wire)
    if space == 2:
        return agg_fn_from_wire(wire)
    if space == 3:
        return window_fn_from_wire(wire)
    if space == 4:
        return frame_units_from_wire(wire)
    if space == 5:
        return frame_bound_from_wire(wire)
    if space == 6:
        return join_type_from_wire(wire)
    if space == 7:
        return join_algo_from_wire(wire)
    if space == 8:
        return asof_direction_from_wire(wire)
    if space == 9:
        return asof_tolerance_kind_from_wire(wire)
    if space == 10:
        return correlated_kind_from_wire(wire)
    if space == 11:
        return source_type_from_wire(wire)
    if space == 12:
        return source_orientation_from_wire(wire)
    if space == 13:
        return source_variant_tag_from_wire(wire)
    if space == 14:
        return binary_op_from_wire(wire)
    if space == 15:
        return unary_op_from_wire(wire)
    if space == 16:
        return string_op_from_wire(wire)
    if space == 17:
        return string_fn_from_wire(wire)
    if space == 18:
        return string_fn_n_from_wire(wire)
    if space == 19:
        return col_side_from_wire(wire)
    if space == 20:
        return math_fn1_from_wire(wire)
    if space == 21:
        return math_fn2_from_wire(wire)
    if space == 22:
        return extract_field_from_wire(wire)
    if space == 23:
        return regexp_op_from_wire(wire)
    if space == 24:
        return arrow_type_from_wire(wire)
    if space == 25:
        return write_format_from_wire(wire)
    if space == 26:
        return write_compression_from_wire(wire)
    if space == 27:
        return scalar_kind_from_wire(wire)
    if space == 28:
        return scalar_time_unit_from_wire(wire)
    if space == 29:
        return param_tag_from_wire(wire)
    if space == 30:
        return pushdown_gate_mode_from_wire(wire)
    if space == 31:
        return snapshot_policy_from_wire(wire)
    raise Error("plan wire: no such space index " + String(space))


def write_plan_wire_name[W: Writer](mut writer: W, space: Int, wire: Int32):
    """WRITE the stable wire NAME. Total — this is the diagnostic path.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the LADDER SHAPE banner at
    the top of this file. Dispatching to the per-space WRITERS (not to
    the `String` wrappers) is what keeps a `Writer`-holding caller free
    of an intermediate heap `String` per rendered name.
    """
    if space == 0:
        write_plan_tag_wire_name(writer, wire)
        return
    if space == 1:
        write_expr_tag_wire_name(writer, wire)
        return
    if space == 2:
        write_agg_fn_wire_name(writer, wire)
        return
    if space == 3:
        write_window_fn_wire_name(writer, wire)
        return
    if space == 4:
        write_frame_units_wire_name(writer, wire)
        return
    if space == 5:
        write_frame_bound_wire_name(writer, wire)
        return
    if space == 6:
        write_join_type_wire_name(writer, wire)
        return
    if space == 7:
        write_join_algo_wire_name(writer, wire)
        return
    if space == 8:
        write_asof_direction_wire_name(writer, wire)
        return
    if space == 9:
        write_asof_tolerance_kind_wire_name(writer, wire)
        return
    if space == 10:
        write_correlated_kind_wire_name(writer, wire)
        return
    if space == 11:
        write_source_type_wire_name(writer, wire)
        return
    if space == 12:
        write_source_orientation_wire_name(writer, wire)
        return
    if space == 13:
        write_source_variant_tag_wire_name(writer, wire)
        return
    if space == 14:
        write_binary_op_wire_name(writer, wire)
        return
    if space == 15:
        write_unary_op_wire_name(writer, wire)
        return
    if space == 16:
        write_string_op_wire_name(writer, wire)
        return
    if space == 17:
        write_string_fn_wire_name(writer, wire)
        return
    if space == 18:
        write_string_fn_n_wire_name(writer, wire)
        return
    if space == 19:
        write_col_side_wire_name(writer, wire)
        return
    if space == 20:
        write_math_fn1_wire_name(writer, wire)
        return
    if space == 21:
        write_math_fn2_wire_name(writer, wire)
        return
    if space == 22:
        write_extract_field_wire_name(writer, wire)
        return
    if space == 23:
        write_regexp_op_wire_name(writer, wire)
        return
    if space == 24:
        write_arrow_type_wire_name(writer, wire)
        return
    if space == 25:
        write_write_format_wire_name(writer, wire)
        return
    if space == 26:
        write_write_compression_wire_name(writer, wire)
        return
    if space == 27:
        write_scalar_kind_wire_name(writer, wire)
        return
    if space == 28:
        write_scalar_time_unit_wire_name(writer, wire)
        return
    if space == 29:
        write_param_tag_wire_name(writer, wire)
        return
    if space == 30:
        write_pushdown_gate_mode_wire_name(writer, wire)
        return
    if space == 31:
        write_snapshot_policy_wire_name(writer, wire)
        return
    writer.write("PlanWireSpace#", space, "/", Int(wire))


def plan_wire_name(space: Int, wire: Int32) -> String:
    """The stable wire NAME, as a String. Total — the diagnostic path.

    A thin `String`-collecting wrapper over `write_plan_wire_name`;
    the LADDER lives there.
    """
    var out = String()
    write_plan_wire_name(out, space, wire)
    return out^
