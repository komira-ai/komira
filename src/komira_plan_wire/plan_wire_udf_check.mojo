# =============================================================================
# plan_wire_udf_check — every call of a `UdfRef` against its list entry
# (docs/design/optimized_plan_udfs.md §10.2, §10.4; optimized_plan.md §6.1)
# =============================================================================
#
# `plan_wire_udf.mojo` refuses a list entry that is wrong on its own. This
# module refuses a plan whose CALLS disagree with the entries they name. It
# runs on a decoded plan in both contexts, after the value gate, and a caller
# that builds a plan in process can run it too (`plan_wire_check_udfs`). Each
# refusal carries the design's token:
#
#   OPTIMIZED_UDF_UNDECLARED                 a `udf_index` past the list (§6.1)
#   OPTIMIZED_UDF_KIND_ARM_MISMATCH          an arm whose entry has another
#                                            kind (§10.2)
#   OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE an AGGREGATE entry called
#                                            anywhere but as an AGG_UDF
#                                            measure, or an AGG_UDF measure
#                                            whose argument is anything but a
#                                            call of an AGGREGATE entry (§10.4)
#   OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH     an argument, a step literal or a
#                                            frame or row input whose type is
#                                            not `arg_types` exactly (§10.4)
#   OPTIMIZED_UDF_READ_SET_COLUMN_UNKNOWN    a frame read-set name the child
#                                            does not output (§10.4)
#   OPTIMIZED_UDF_READ_SET_INVALID           a ROW call or a read set over an
#                                            input with two columns of one
#                                            name (§10.4)
#   OPTIMIZED_UDF_READ_SET_GROUP_KEY         a grouped frame whose read set
#                                            omits a column its `group_by`
#                                            reads (§10.4)
#   OPTIMIZED_UDF_SCHEMA_DISAGREES           a node output schema that is not
#                                            what the `return_type` it derives
#                                            from says (§10.4)
#   OPTIMIZED_UDF_IN_SCAN_FILTER             a call in a scan's pushed filter
#                                            (§10.2, optimized_plan.md §7.2)
#   OPTIMIZED_UDF_LEGACY_FORM                `WireUdfCall` or a node-level
#                                            `WireUdf` in OPTIMIZED (§10.4);
#                                            the decoder raises it as it meets
#                                            the arm
#
# ★ UNSET IS NEVER "WHATEVER `arg_types` SAYS". A frame or a ROW call with no
# read set receives every input column, so its input must equal `arg_types`
# in names, types and order; a set read set is held to `arg_types` name by
# name (`plan_wire_udf.mojo`) and, for a frame, to the child's columns here.
#
# WHAT IS NOT HERE, AND WHY. The design's §10.4 also names refusals that need
# fields this tree's wire does not carry yet: an aggregate's decomposition
# `mode` (OPTIMIZED_UDF_AGGREGATE_NOT_DECOMPOSABLE, and
# OPTIMIZED_UDF_STATE_TYPE_MISSING, which is the same question asked of a
# measure) and the exchange arm (OPTIMIZED_UDF_GROUP_EXCHANGE_INCONSISTENT)
# arrive with optimized_plan.md §12 stage 3. Host admission
# (OPTIMIZED_UDF_KIND_UNSUPPORTED, OPTIMIZED_UDF_DESCRIPTOR_INVALID) is stage
# 12, and the `needs` agreement (OPTIMIZED_UDF_UNREFERENCED,
# OPTIMIZED_UDF_RUNTIME_UNDECLARED) belongs to the body codec of stage 5.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_UDF
from komira_plan_expr.expr import (
    Expr,
    EXPR_AGG_FN,
    EXPR_ALIAS,
    EXPR_BETWEEN,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_IDX,
    EXPR_COL_REF,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_EXTRACT,
    EXPR_IN_LIST,
    EXPR_JSON_EXTRACT,
    EXPR_LITERAL,
    EXPR_MAP_GET,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_REGEXP,
    EXPR_SORT_KEY,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_STRING_OP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_SUBSTRING,
    EXPR_UDF_APPLY,
    EXPR_UDF_CALL,
    EXPR_UNARY_OP,
    EXPR_WHEN,
    EXPR_WINDOW_FN,
    expr_tag_name,
)
from komira_plan_expr.expr_walk import walk_expr_column_refs, ordered_name_sink
from komira_plan_expr.udf_type import UdfType, udf_type_same
from komira_plan_expr.udf_type_field import field_to_udf_type, udf_type_to_field
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_ASOF_JOIN,
    PLAN_CAST_TO_VARCHAR,
    PLAN_CSE_REF,
    PLAN_DISTINCT,
    PLAN_EXCHANGE,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_MAP_BATCHES,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_STEP,
    PLAN_TOPN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    _infer_expr_field,
    plan_tag_name,
)
from komira_plan_ir.corr_subquery import corr_subq_inner_plan_ref
from komira_plan_ir.udf_ref import (
    UdfRef,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_MAP_BATCHES_COLUMN,
    UDF_REF_KIND_AGGREGATE,
    UDF_REF_KIND_STEP,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    udf_ref_kind_name,
)

from .plan_wire_udf import OPTIMIZED_UDF_READ_SET_INVALID, _check_udf_ref
from .plan_wire_codec import PLAN_WIRE_FIELD_TOO_DEEP


comptime OPTIMIZED_UDF_UNDECLARED: String = "OPTIMIZED_UDF_UNDECLARED"
comptime OPTIMIZED_UDF_KIND_ARM_MISMATCH: String = "OPTIMIZED_UDF_KIND_ARM_MISMATCH"
comptime OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE: String = "OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE"
comptime OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH: String = "OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH"
comptime OPTIMIZED_UDF_READ_SET_COLUMN_UNKNOWN: String = "OPTIMIZED_UDF_READ_SET_COLUMN_UNKNOWN"
comptime OPTIMIZED_UDF_READ_SET_GROUP_KEY: String = "OPTIMIZED_UDF_READ_SET_GROUP_KEY"
comptime OPTIMIZED_UDF_SCHEMA_DISAGREES: String = "OPTIMIZED_UDF_SCHEMA_DISAGREES"
comptime OPTIMIZED_UDF_IN_SCAN_FILTER: String = "OPTIMIZED_UDF_IN_SCAN_FILTER"
comptime OPTIMIZED_UDF_LEGACY_FORM: String = "OPTIMIZED_UDF_LEGACY_FORM"
comptime PLAN_WIRE_UDF_CHECK_UNMODELLED_TAG: String = "PLAN_WIRE_UDF_CHECK_UNMODELLED_TAG"
"""A plan or expression tag this check has no arm for: a bug in this build
(a tag added without its arm here), never a fault of the plan."""


def legacy_form_error(where: String) -> Error:
    """`OPTIMIZED_UDF_LEGACY_FORM` for `where`: a registered Mojo function by
    name (`WireUdfCall`, or a node-level `WireUdf`) in an optimized plan."""
    return Error(
        OPTIMIZED_UDF_LEGACY_FORM + ": " + where + " is a UDF keyed by a name"
        + " that the receiver resolves in its own registry. An optimized plan"
        + " names user code by `UdfRef` (WireUdfApply, WireMapBatchesNode,"
        + " WireStepNode); the named form stays RAW-only"
        + " (optimized_plan_udfs.md §10.4)"
    )


def udf_entry_index(udfs: List[UdfRef], index: Int, where: String) raises -> Int:
    """`index` when the list has an entry there; `OPTIMIZED_UDF_UNDECLARED`
    otherwise."""
    if index < 0 or index >= len(udfs):
        raise Error(
            OPTIMIZED_UDF_UNDECLARED + ": " + where + " names udf_index "
            + String(index) + ", and the plan declares " + String(len(udfs))
            + " UdfRef entr" + ("y" if len(udfs) == 1 else "ies")
        )
    return index


def _kind_error(where: String, arm: String, u: UdfRef, index: Int) -> Error:
    return Error(
        OPTIMIZED_UDF_KIND_ARM_MISMATCH + ": " + where + " is a " + arm
        + " naming UdfRef " + String(index) + ", whose kind is "
        + udf_ref_kind_name(u.kind) + "; a runtime binds one argument schema"
        + " per UdfRef, so one entry serves one call shape (§10.2)"
    )


# =============================================================================
# Types
# =============================================================================


def _empty_schema() -> Schema:
    var b = SchemaBuilder()
    return b.build()


def _same_type(got: Field, want: UdfType) -> Bool:
    """`got` is `want` exactly, children included; the root's name is not
    compared (an argument's name is the expression's, not the type's)."""
    return udf_type_same(field_to_udf_type(got), want, False)


def _type_text(t: UdfType) -> String:
    var out = String()
    t.write_to(out)
    return out^


def _field_text(f: Field) -> String:
    return _type_text(field_to_udf_type(f))


def udf_column_field(t: UdfType, where: String) raises -> Field:
    """`t` as one column of a node's output schema. A `Field` holds one level
    of children, so a type whose children have children of their own cannot
    be a column here (`PLAN_WIRE_FIELD_TOO_DEEP`)."""
    if t.depth() > 2:
        raise Error(
            PLAN_WIRE_FIELD_TOO_DEEP + ": " + where + " has the type "
            + _type_text(t) + ", nested " + String(t.depth()) + " deep; an"
            + " output column holds what the engine's Schema stores, one level"
            + " of children"
        )
    return udf_type_to_field(t)


def udf_frame_schema(u: UdfRef, index: Int, where: String) raises -> Schema:
    """The output schema of a frame or step node: the children of the
    entry's `return_type`, which must be a struct (§10.4)."""
    ref t = u.return_type.value()
    if t.arrow_type.type_id != ArrowType.STRUCT.type_id:
        raise Error(
            OPTIMIZED_UDF_SCHEMA_DISAGREES + ": " + where + " names UdfRef "
            + String(index) + ", whose return_type " + _type_text(t) + " is"
            + " not a struct, so it names no columns for the node to output"
        )
    var b = SchemaBuilder()
    for i in range(len(t.children)):
        b.add_field(udf_column_field(t.children[i], where + " column '" + t.children[i].name + "'"))
    return b.build()


# =============================================================================
# The node output schema against the return type (decoder hook)
# =============================================================================


def _under_alias(e: Expr) -> Bool:
    """True when `e` is a UDF call, under any number of aliases."""
    if e.tag == EXPR_UDF_APPLY:
        return True
    if e.tag == EXPR_ALIAS:
        return _under_alias(e.alias_child_ref())
    return False


def _call_type(e: Expr) -> UdfType:
    """The type of the UDF call `e` is, under any number of aliases. Requires
    `_under_alias(e)`."""
    if e.tag == EXPR_ALIAS:
        return _call_type(e.alias_child_ref())
    return e.udf_apply_return_type_ref().copy()


def check_udf_output_schema(
    node: LogicalPlan, wire: Schema, where: String
) raises:
    """Before the decoder compares a node's derived output schema with the
    one the wire carried, name the columns that a UDF's `return_type`
    derives: a frame's or step's whole schema, and each project column or
    AGG_UDF measure that is a UDF call (`OPTIMIZED_UDF_SCHEMA_DISAGREES`).
    Every other difference is the generic `PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED`
    that follows."""
    var derived = node.output_schema.copy()
    if node.tag == PLAN_MAP_BATCHES or node.tag == PLAN_STEP:
        var same = derived.num_columns() == wire.num_columns()
        var i = 0
        while same and i < derived.num_columns():
            same = udf_type_same(
                field_to_udf_type(derived.field_at(i)),
                field_to_udf_type(wire.field_at(i)),
                True,
            )
            i += 1
        if not same:
            raise Error(
                OPTIMIZED_UDF_SCHEMA_DISAGREES + ": " + where + " carries an"
                + " output schema that is not the columns of its UdfRef's"
                + " return_type. return_type columns="
                + _schema_text(derived) + " wire=" + _schema_text(wire)
            )
        return
    if node.tag == PLAN_PROJECT:
        ref d = node.project_data_ref()
        for i in range(len(d.exprs)):
            if _under_alias(d.exprs[i]):
                _udf_column_agrees(_call_type(d.exprs[i]), wire, i, where)
        return
    if node.tag == PLAN_AGGREGATE:
        ref d = node.aggregate_data_ref()
        for j in range(len(d.agg_exprs)):
            ref a = d.agg_exprs[j]
            if a.func == AGG_UDF and a.child and _under_alias(a.child.value()):
                _udf_column_agrees(
                    _call_type(a.child.value()), wire, len(d.group_by) + j, where
                )


def _udf_column_agrees(
    want: UdfType, wire: Schema, i: Int, where: String
) raises:
    """Output column `i` is a UDF call of type `want`. A type deeper than a
    column holds is refused first (`udf_column_field`), so a truncated
    comparison cannot pass."""
    _ = udf_column_field(want, where + " column " + String(i))
    if i >= wire.num_columns():
        return
    var got = wire.field_at(i)
    if not udf_type_same(want, field_to_udf_type(got), False):
        raise Error(
            OPTIMIZED_UDF_SCHEMA_DISAGREES + ": " + where + " column " + String(i)
            + " ('" + got.name + "') is a UDF call whose UdfRef return_type is "
            + _type_text(want) + ", and the wire says " + _field_text(got)
        )


def _schema_text(s: Schema) raises -> String:
    var out = String("[")
    for i in range(s.num_columns()):
        if i > 0:
            out += ", "
        out += _field_text(s.field_at(i))
    return out + "]"


# =============================================================================
# The walk
# =============================================================================


def _has_dup_name(s: Schema, name: String) -> Bool:
    var n = 0
    for i in range(s.num_columns()):
        if s.field_name(i) == name:
            n += 1
    return n > 1


def _first_dup_name(s: Schema) -> String:
    for i in range(s.num_columns()):
        for j in range(i + 1, s.num_columns()):
            if s.field_name(i) == s.field_name(j):
                return s.field_name(i)
    return String("")


def _input_is_arg_types(
    input: Schema, u: UdfRef, index: Int, where: String
) raises:
    """An unset read set: the input is `arg_types`, names, types and order."""
    var n = input.num_columns()
    if n != len(u.arg_types):
        raise Error(
            OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH + ": " + where + " UdfRef "
            + String(index) + " has no read set, so it receives every input"
            + " column, and its input has " + String(n) + " columns where"
            + " arg_types lists " + String(len(u.arg_types))
            + ". Unset never means \"whatever arg_types lists\" (§10.4)"
        )
    for i in range(n):
        var f = input.field_at(i)
        if f.name != u.arg_types[i].name or not _same_type(f, u.arg_types[i]):
            raise Error(
                OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH + ": " + where + " UdfRef "
                + String(index) + " has no read set, and input column " + String(i)
                + " '" + f.name + "' " + _field_text(f) + " is not arg_types["
                + String(i) + "] '" + u.arg_types[i].name + "' "
                + _type_text(u.arg_types[i])
            )


def _check_apply(
    e: Expr,
    input: Schema,
    udfs: List[UdfRef],
    as_measure: Bool,
    where: String,
) raises:
    """One call of a `UdfRef` as an expression: its kind, its arguments, and
    for a ROW its input. `as_measure` is true for exactly one position, the
    argument of an AGG_UDF measure."""
    var index = udf_entry_index(udfs, e.udf_apply_index(), where)
    ref u = udfs[index]
    if u.kind == UDF_REF_KIND_AGGREGATE and not as_measure:
        raise Error(
            OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE + ": " + where + " calls"
            + " UdfRef " + String(index) + ", an AGGREGATE, outside an AGG_UDF"
            + " measure; an AGGREGATE entry is admitted only as the argument of"
            + " one (§10.4)"
        )
    if as_measure and u.kind != UDF_REF_KIND_AGGREGATE:
        raise Error(
            OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE + ": " + where + " is an"
            + " AGG_UDF measure naming UdfRef " + String(index) + ", whose kind"
            + " is " + udf_ref_kind_name(u.kind) + "; the measure names only an"
            + " AGGREGATE (§10.4)"
        )
    if (
        u.kind != UDF_REF_KIND_SCALAR
        and u.kind != UDF_REF_KIND_ROW
        and u.kind != UDF_REF_KIND_MAP_BATCHES_COLUMN
        and u.kind != UDF_REF_KIND_AGGREGATE
    ):
        raise _kind_error(where, "WireUdfApply", u, index)
    if not udf_type_same(e.udf_apply_return_type_ref(), u.return_type.value(), True):
        raise Error(
            OPTIMIZED_UDF_SCHEMA_DISAGREES + ": " + where + " carries the type "
            + _type_text(e.udf_apply_return_type_ref()) + " for UdfRef "
            + String(index) + ", whose return_type is "
            + _type_text(u.return_type.value())
        )
    if u.kind == UDF_REF_KIND_ROW:
        var dup = _first_dup_name(input)
        if dup.byte_length() > 0:
            raise Error(
                OPTIMIZED_UDF_READ_SET_INVALID + ": " + where + " is a ROW call"
                + " over an input with two columns named '" + dup + "', so a"
                + " field read by name is ambiguous (§10.4)"
            )
        if not u.read_set:
            _input_is_arg_types(input, u, index, where)
    var n = e.udf_apply_num_args()
    if n != len(u.arg_types):
        raise Error(
            OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH + ": " + where + " passes "
            + String(n) + " arguments to UdfRef " + String(index) + ", whose"
            + " arg_types lists " + String(len(u.arg_types))
        )
    for i in range(n):
        ref a = e.udf_apply_arg_ref(i)
        var f = _infer_expr_field(a, input)
        if not _same_type(f, u.arg_types[i]):
            raise Error(
                OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH + ": " + where + " argument "
                + String(i) + " of UdfRef " + String(index) + " has the type "
                + _field_text(f) + " where arg_types[" + String(i) + "] is "
                + _type_text(u.arg_types[i]) + "; the producer inserts any cast"
                + " (§10.4)"
            )
        _check_expr(a, input, udfs, where)


def _check_expr(
    e: Expr, input: Schema, udfs: List[UdfRef], where: String
) raises:
    """Every UDF call in `e`, at any depth, against the input in scope."""
    var calls = 0
    _walk_expr(e, input, udfs, where, True, calls)


def _count_calls(e: Expr, udfs: List[UdfRef]) raises -> Int:
    """How many UDF calls `e` holds at any depth, checking none of them."""
    var calls = 0
    _walk_expr(e, _empty_schema(), udfs, String(""), False, calls)
    return calls


def _walk_expr(
    e: Expr,
    input: Schema,
    udfs: List[UdfRef],
    where: String,
    check: Bool,
    mut calls: Int,
) raises:
    """THE ONE LADDER over expression tags, for both uses: `check` true holds
    each UDF call to its entry (`_check_apply`, which descends its
    arguments); false only counts calls. Every `EXPR_*` tag has an arm: a
    fall-through would say "no call here" about a subtree it never
    entered."""
    var tag = e.tag
    if tag == EXPR_UDF_APPLY:
        calls += 1
        if check:
            _check_apply(e, input, udfs, False, where)
        else:
            for i in range(e.udf_apply_num_args()):
                _walk_expr(e.udf_apply_arg_ref(i), input, udfs, where, check, calls)
    elif (
        tag == EXPR_COL_REF
        or tag == EXPR_COL_IDX
        or tag == EXPR_LITERAL
        or tag == EXPR_WINDOW_FN
        or tag == EXPR_BETWEEN
        or tag == EXPR_SORT_KEY
    ):
        return
    elif tag == EXPR_UNARY_OP:
        _walk_expr(e.unary_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_CAST:
        _walk_expr(e.cast_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_ALIAS:
        _walk_expr(e.alias_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_STRING_OP:
        _walk_expr(e.string_op_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_REGEXP:
        _walk_expr(e.regexp_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_SUBSTRING:
        _walk_expr(e.substring_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_STRING_FN:
        _walk_expr(e.string_fn_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_UDF_CALL:
        _walk_expr(e.udf_call_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_EXTRACT:
        _walk_expr(e.extract_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_MATH_FN:
        _walk_expr(e.math_fn_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_AGG_FN:
        _walk_expr(e.agg_fn_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_IN_LIST:
        _walk_expr(e.in_list_child_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_STRUCT_FIELD:
        _walk_expr(e.struct_field_parent_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_STRUCT_FIELD_IDX:
        _walk_expr(e.struct_field_idx_parent_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_JSON_EXTRACT:
        _walk_expr(e.json_extract_parent_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_STRING_FN_N:
        for i in range(e.string_fn_n_num_args()):
            _walk_expr(e.string_fn_n_arg_ref(i), input, udfs, where, check, calls)
    elif tag == EXPR_BINARY_OP:
        _walk_expr(e.binary_left_ref(), input, udfs, where, check, calls)
        _walk_expr(e.binary_right_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_MATH_FN2:
        _walk_expr(e.math_fn2_left_ref(), input, udfs, where, check, calls)
        _walk_expr(e.math_fn2_right_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_MAP_GET:
        _walk_expr(e.map_get_parent_ref(), input, udfs, where, check, calls)
        _walk_expr(e.map_get_key_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_WHEN:
        for i in range(e.when_num_cases()):
            _walk_expr(e.when_case_condition_ref(i), input, udfs, where, check, calls)
            _walk_expr(e.when_case_result_ref(i), input, udfs, where, check, calls)
        _walk_expr(e.when_default_ref(), input, udfs, where, check, calls)
    elif tag == EXPR_CORRELATED_SUBQUERY:
        # The inner plan is a plan: its calls are checked against its own
        # inputs, with the same list.
        _check_plan(corr_subq_inner_plan_ref(e), udfs)
    else:
        raise Error(
            PLAN_WIRE_UDF_CHECK_UNMODELLED_TAG + ": " + where + " holds"
            + " expression tag " + expr_tag_name(tag) + ", which the UDF check"
            + " has no arm for; a bug in this build, not in the plan"
        )


def _check_agg(a: AggExpr, input: Schema, udfs: List[UdfRef], where: String) raises:
    if a.func != AGG_UDF:
        if a.child:
            _check_expr(a.child.value(), input, udfs, where)
        if a.child1:
            _check_expr(a.child1.value(), input, udfs, where)
        if a.child2:
            _check_expr(a.child2.value(), input, udfs, where)
        if a.child3:
            _check_expr(a.child3.value(), input, udfs, where)
        return
    if not a.child or a.child.value().tag != EXPR_UDF_APPLY:
        raise Error(
            OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE + ": " + where + " is an"
            + " AGG_UDF measure whose argument is not a call of an AGGREGATE"
            + " UdfRef (§10.4)"
        )
    if Bool(a.child1) or Bool(a.child2) or Bool(a.child3):
        raise Error(
            OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE + ": " + where + " is an"
            + " AGG_UDF measure with more than one argument; its one argument"
            + " is the call (§10.4)"
        )
    _check_apply(a.child.value(), input, udfs, True, where)


def _check_frame(plan: LogicalPlan, udfs: List[UdfRef]) raises:
    ref d = plan.map_batches_data_ref()
    var where = String("MapBatches")
    var index = udf_entry_index(udfs, d.udf_index, where)
    ref u = udfs[index]
    if u.kind != UDF_REF_KIND_MAP_BATCHES_FRAME:
        raise _kind_error(where, "WireMapBatchesNode", u, index)
    ref input = d.child[].output_schema
    for i in range(len(d.group_by)):
        _check_expr(d.group_by[i], input, udfs, where + " group_by")
    if not u.read_set:
        _input_is_arg_types(input, u, index, where)
        return
    ref names = u.read_set.value()
    for i in range(len(names)):
        var found = -1
        for c in range(input.num_columns()):
            if input.field_name(c) == names[i]:
                found = c
        if found < 0:
            raise Error(
                OPTIMIZED_UDF_READ_SET_COLUMN_UNKNOWN + ": " + where + " UdfRef "
                + String(index) + " reads '" + names[i] + "', which its child"
                + " does not output"
            )
        if _has_dup_name(input, names[i]):
            raise Error(
                OPTIMIZED_UDF_READ_SET_INVALID + ": " + where + " UdfRef "
                + String(index) + " reads '" + names[i] + "', and its child"
                + " outputs two columns of that name (§10.4)"
            )
        var f = input.field_at(found)
        if not _same_type(f, u.arg_types[i]):
            raise Error(
                OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH + ": " + where + " UdfRef "
                + String(index) + " reads '" + names[i] + "' as "
                + _type_text(u.arg_types[i]) + ", and the child outputs "
                + _field_text(f)
            )
    for g in range(len(d.group_by)):
        var cols = List[String]()
        _col_refs(d.group_by[g], cols)
        for k in range(len(cols)):
            var named = False
            for i in range(len(names)):
                if names[i] == cols[k]:
                    named = True
            if not named:
                raise Error(
                    OPTIMIZED_UDF_READ_SET_GROUP_KEY + ": " + where + " UdfRef "
                    + String(index) + " groups by a key that reads '" + cols[k]
                    + "', and its read set does not name it; a grouped frame's"
                    + " read set contains every column its group_by reads"
                    + " (§10.2)"
                )


def _col_refs(e: Expr, mut out: List[String]):
    """The column names `e` reads (the engine's one column walk)."""
    var sink = ordered_name_sink(out)
    walk_expr_column_refs(e, sink)


def _check_step(plan: LogicalPlan, udfs: List[UdfRef]) raises:
    ref d = plan.step_data_ref()
    var where = String("Step")
    var index = udf_entry_index(udfs, d.udf_index, where)
    ref u = udfs[index]
    if u.kind != UDF_REF_KIND_STEP:
        raise _kind_error(where, "WireStepNode", u, index)
    if len(d.args) != len(u.arg_types):
        raise Error(
            OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH + ": " + where + " passes "
            + String(len(d.args)) + " literals to UdfRef " + String(index)
            + ", whose arg_types lists " + String(len(u.arg_types))
        )
    for i in range(len(d.args)):
        var f = _infer_expr_field(
            Expr.literal(d.args[i].copy()), _empty_schema()
        )
        if not _same_type(f, u.arg_types[i]):
            raise Error(
                OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH + ": " + where + " literal "
                + String(i) + " has the type " + _field_text(f) + " where"
                + " arg_types[" + String(i) + "] is " + _type_text(u.arg_types[i])
            )


def _check_plan(plan: LogicalPlan, udfs: List[UdfRef]) raises:
    var tag = plan.tag
    if tag == PLAN_SCAN:
        ref d = plan.scan_data_ref()
        if d.filter and _count_calls(d.filter.value(), udfs) > 0:
            raise Error(
                OPTIMIZED_UDF_IN_SCAN_FILTER + ": a scan's pushed filter calls"
                + " a UdfRef; a UDF is never pushed into a scan's filter"
                + " (§10.2, optimized_plan.md §7.2)"
            )
    elif tag == PLAN_FILTER:
        ref d = plan.filter_data_ref()
        _check_plan(d.child[], udfs)
        _check_expr(d.predicate, d.child[].output_schema, udfs, "Filter predicate")
    elif tag == PLAN_PROJECT:
        ref d = plan.project_data_ref()
        _check_plan(d.child[], udfs)
        for i in range(len(d.exprs)):
            _check_expr(
                d.exprs[i], d.child[].output_schema, udfs,
                "Project expression " + String(i),
            )
    elif tag == PLAN_AGGREGATE:
        ref d = plan.aggregate_data_ref()
        _check_plan(d.child[], udfs)
        for i in range(len(d.group_by)):
            _check_expr(
                d.group_by[i], d.child[].output_schema, udfs,
                "Aggregate group key " + String(i),
            )
        for i in range(len(d.agg_exprs)):
            _check_agg(
                d.agg_exprs[i], d.child[].output_schema, udfs,
                "Aggregate measure " + String(i),
            )
    elif tag == PLAN_JOIN:
        ref d = plan.join_data_ref()
        _check_plan(d.left[], udfs)
        _check_plan(d.right[], udfs)
        if d.residual:
            # The residual reads the joined row, so the join's own output is
            # its input.
            _check_expr(d.residual.value()[], plan.output_schema, udfs, "Join residual")
    elif tag == PLAN_SORT:
        _check_plan(plan.sort_data_ref().child[], udfs)
    elif tag == PLAN_LIMIT:
        _check_plan(plan.limit_data_ref().child[], udfs)
    elif tag == PLAN_DISTINCT:
        _check_plan(plan.distinct_data_ref().child[], udfs)
    elif tag == PLAN_TOPN:
        _check_plan(plan.topn_data_ref().child[], udfs)
    elif tag == PLAN_PARTITION_BY:
        _check_plan(plan.partition_by_data_ref().child[], udfs)
    elif tag == PLAN_PARTITION_TOPN:
        _check_plan(plan.partition_topn_data_ref().child[], udfs)
    elif tag == PLAN_ASOF_JOIN:
        _check_plan(plan.asof_join_data_ref().left[], udfs)
        _check_plan(plan.asof_join_data_ref().right[], udfs)
    elif tag == PLAN_UNION:
        ref d = plan.union_data_ref()
        for i in range(len(d.children)):
            _check_plan(d.children[i][], udfs)
    elif tag == PLAN_CAST_TO_VARCHAR:
        _check_plan(plan.cast_to_varchar_data_ref().child[], udfs)
    elif tag == PLAN_EXCHANGE:
        _check_plan(plan.exchange_data_ref().child[], udfs)
    elif tag == PLAN_MAP_BATCHES:
        _check_plan(plan.map_batches_data_ref().child[], udfs)
        _check_frame(plan, udfs)
    elif tag == PLAN_STEP:
        _check_step(plan, udfs)
    elif tag == PLAN_VIEW_REF or tag == PLAN_CSE_REF:
        # Leaves whose subtree lives elsewhere; nothing here calls a UdfRef.
        pass
    else:
        raise Error(
            PLAN_WIRE_UDF_CHECK_UNMODELLED_TAG + ": plan tag "
            + plan_tag_name(tag) + " has no arm in the UDF check; a bug in"
            + " this build, not in the plan"
        )


def plan_wire_check_udfs(plan: LogicalPlan, udfs: List[UdfRef]) raises:
    """Refuse a plan whose UDF calls disagree with the `UdfRef` list they
    index (this module's header). The decoders run it on every plan, after
    the value gate; a caller that builds a plan in process runs it before
    trusting one. Each entry of `udfs` is checked on its own first, as the
    decoders do (`udf_ref_from_bytes`)."""
    for i in range(len(udfs)):
        _check_udf_ref(udfs[i], i)
    _check_plan(plan, udfs)
