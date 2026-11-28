# =============================================================================
# udf_check -- what the cutter holds a user-function call to
# =============================================================================
#
# A plan names its user functions by index in the `UdfRef` list beside it
# (`LoweringInputs.udfs`). Before a UDF arm cuts a call, the call is held to
# its entry here, against the input the call reads:
#
#   * the index names an entry, and the entry's kind is one the node or call
#     takes (a frame node MAP_BATCHES_FRAME, a step node STEP, a call in an
#     expression SCALAR, ROW or MAP_BATCHES_COLUMN), else
#     LOWERING_UDF_UNSERVED;
#   * a ROW or MAP_BATCHES_FRAME function declares a read set: the columns it
#     receives, and nothing else. A function that declares none, a ROW call
#     whose argument reads a column outside the set, and a frame whose group
#     key does, are refused with LOWERING_UDF_UNDECLARED_READ naming the
#     column and the set. There is no every-column path: an unset read set is
#     never widened to the input's columns;
#   * every name of a read set is a column of the input, exactly once, else
#     LOWERING_UDF_UNSERVED;
#   * a call passes one argument per declared argument type, a step one literal
#     per declared type, else LOWERING_UDF_UNSERVED.
#
# What lowering cannot see is the code: a function whose code reads a field its
# read set does not declare is stopped by its runtime when it runs
# (UDF_FIELD_NOT_DECLARED, docs/design/udf_runtime_interface.md), because the
# engine passes it only the declared columns.
#
# `_udf_apply_count` is the one walk over expression tags that finds calls
# (EXPR_UDF_APPLY) at any depth. It has an arm for every tag: a fall-through
# would answer "no call here" about a subtree it never entered, so a tag it
# does not model is refused by name.
# =============================================================================

from arrow.schema import Schema
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_UDF_UNDECLARED_READ,
    LOWERING_UDF_UNSERVED,
)
from plan_expr.agg_expr import AggExpr
from plan_expr.expr import (
    Expr,
    EXPR_AGG_FN,
    EXPR_ALIAS,
    EXPR_BETWEEN,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_IDX,
    EXPR_COL_REF,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_DATE_ADD,
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
from plan_expr.expr_walk import ordered_name_sink, walk_expr_column_refs
from plan_ir.logical_plan import LogicalPlan, plan_tag_name
from plan_ir.udf_ref import (
    UdfRef,
    UDF_REF_KIND_MAP_BATCHES_COLUMN,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_STEP,
    udf_ref_kind_name,
)
from physical_plan.udf_call_spec import UdfCallSpec


def _udf_unserved(node: LogicalPlan, why: String) -> Error:
    """The LOWERING_UDF_UNSERVED refusal of `node`, naming why."""
    return Error(
        String(LOWERING_UDF_UNSERVED)
        + ": "
        + plan_tag_name(node.tag)
        + " ("
        + why
        + ") is not cut"
    )


def _set_text(names: List[String]) -> String:
    var out = String("[")
    for i in range(len(names)):
        if i > 0:
            out += ", "
        out += names[i]
    return out + "]"


def _undeclared(
    node: LogicalPlan, index: Int, u: UdfRef, what: String
) -> Error:
    return Error(
        String(LOWERING_UDF_UNDECLARED_READ)
        + ": "
        + plan_tag_name(node.tag)
        + " UdfRef "
        + String(index)
        + " ("
        + udf_ref_kind_name(u.kind)
        + ") "
        + what
    )


def _udf_entry(
    node: LogicalPlan, inputs: LoweringInputs, index: Int
) raises -> Int:
    """`index`, when the plan's `UdfRef` list has an entry there."""
    if index < 0 or index >= len(inputs.udfs):
        raise _udf_unserved(
            node,
            "UdfRef "
            + String(index)
            + " is not in the plan's list, which holds "
            + String(len(inputs.udfs)),
        )
    return index


def _udf_kind_is(
    node: LogicalPlan, u: UdfRef, index: Int, kind: UInt8, arm: String
) raises:
    """Refuse an entry whose kind is not `kind`, the one `arm` calls."""
    if u.kind != kind:
        raise _udf_unserved(
            node,
            "UdfRef "
            + String(index)
            + " is a "
            + udf_ref_kind_name(u.kind)
            + " function, and "
            + arm
            + " calls a "
            + udf_ref_kind_name(kind)
            + " one",
        )


def _declared_reads(
    node: LogicalPlan, u: UdfRef, index: Int, input: Schema
) raises -> List[String]:
    """The read set of a ROW or frame entry: the columns of `input` it
    receives, in its order. Refuses an entry that declares none, and a name
    that is not one column of `input`."""
    if not u.read_set:
        raise _undeclared(
            node,
            index,
            u,
            "declares no read set, so every column it would receive is"
            " undeclared; the producer names the columns it reads",
        )
    ref names = u.read_set.value()
    for i in range(len(names)):
        var found = 0
        for c in range(input.num_columns()):
            if input.field_name(c) == names[i]:
                found += 1
        if found != 1:
            var why = String("which its input does not output")
            if found > 1:
                why = "which its input outputs " + String(found) + " times"
            raise _udf_unserved(
                node,
                "UdfRef "
                + String(index)
                + " declares '"
                + names[i]
                + "' in its read set, "
                + why,
            )
    return names.copy()


def _column_refs(e: Expr) -> List[String]:
    """The columns `e` reads, in first-seen order, repeats kept."""
    var out = List[String]()
    var sink = ordered_name_sink(out)
    walk_expr_column_refs(e, sink)
    return out^


def _reads_are_declared(
    node: LogicalPlan,
    u: UdfRef,
    index: Int,
    declared: List[String],
    e: Expr,
    what: String,
) raises:
    """Refuse `e` (`what`: the call's argument, a group key) when it reads a
    column the read set `declared` does not name."""
    var cols = _column_refs(e)
    for k in range(len(cols)):
        var named = False
        for i in range(len(declared)):
            if declared[i] == cols[k]:
                named = True
        if not named:
            raise _undeclared(
                node,
                index,
                u,
                "reads '"
                + cols[k]
                + "' through "
                + what
                + ", which its read set "
                + _set_text(declared)
                + " does not declare",
            )


def _udf_apply_count(e: Expr) raises -> Int:
    """How many calls of a `UdfRef` (EXPR_UDF_APPLY) `e` holds, at any depth,
    inside another call's arguments included."""
    var tag = e.tag
    if tag == EXPR_UDF_APPLY:
        var n = 1
        for i in range(e.udf_apply_num_args()):
            n += _udf_apply_count(e.udf_apply_arg_ref(i))
        return n
    if (
        tag == EXPR_COL_REF
        or tag == EXPR_COL_IDX
        or tag == EXPR_LITERAL
        or tag == EXPR_WINDOW_FN
        or tag == EXPR_BETWEEN
        or tag == EXPR_SORT_KEY
    ):
        return 0
    if tag == EXPR_CORRELATED_SUBQUERY:
        # The subquery's body is a plan of its own, never cut into this
        # segment: the purity gate refuses a segment that holds one.
        return 0
    if tag == EXPR_UNARY_OP:
        return _udf_apply_count(e.unary_child_ref())
    if tag == EXPR_CAST:
        return _udf_apply_count(e.cast_child_ref())
    if tag == EXPR_ALIAS:
        return _udf_apply_count(e.alias_child_ref())
    if tag == EXPR_STRING_OP:
        return _udf_apply_count(e.string_op_child_ref())
    if tag == EXPR_REGEXP:
        return _udf_apply_count(e.regexp_child_ref())
    if tag == EXPR_SUBSTRING:
        return _udf_apply_count(e.substring_child_ref())
    if tag == EXPR_STRING_FN:
        return _udf_apply_count(e.string_fn_child_ref())
    if tag == EXPR_UDF_CALL:
        return _udf_apply_count(e.udf_call_child_ref())
    if tag == EXPR_EXTRACT:
        return _udf_apply_count(e.extract_child_ref())
    if tag == EXPR_DATE_ADD:
        return _udf_apply_count(e.date_add_child_ref())
    if tag == EXPR_MATH_FN:
        return _udf_apply_count(e.math_fn_child_ref())
    if tag == EXPR_AGG_FN:
        return _udf_apply_count(e.agg_fn_child_ref())
    if tag == EXPR_IN_LIST:
        return _udf_apply_count(e.in_list_child_ref())
    if tag == EXPR_STRUCT_FIELD:
        return _udf_apply_count(e.struct_field_parent_ref())
    if tag == EXPR_STRUCT_FIELD_IDX:
        return _udf_apply_count(e.struct_field_idx_parent_ref())
    if tag == EXPR_JSON_EXTRACT:
        return _udf_apply_count(e.json_extract_parent_ref())
    if tag == EXPR_STRING_FN_N:
        var n = 0
        for i in range(e.string_fn_n_num_args()):
            n += _udf_apply_count(e.string_fn_n_arg_ref(i))
        return n
    if tag == EXPR_BINARY_OP:
        return _udf_apply_count(e.binary_left_ref()) + _udf_apply_count(
            e.binary_right_ref()
        )
    if tag == EXPR_MATH_FN2:
        return _udf_apply_count(e.math_fn2_left_ref()) + _udf_apply_count(
            e.math_fn2_right_ref()
        )
    if tag == EXPR_MAP_GET:
        return _udf_apply_count(e.map_get_parent_ref()) + _udf_apply_count(
            e.map_get_key_ref()
        )
    if tag == EXPR_WHEN:
        var n = _udf_apply_count(e.when_default_ref())
        for i in range(e.when_num_cases()):
            n += _udf_apply_count(e.when_case_condition_ref(i))
            n += _udf_apply_count(e.when_case_result_ref(i))
        return n
    raise Error(
        String(LOWERING_UDF_UNSERVED)
        + ": expression tag "
        + expr_tag_name(tag)
        + " has no arm in the walk that finds user-function calls"
    )


def _agg_apply_count(a: AggExpr) raises -> Int:
    """How many calls of a `UdfRef` the arguments of `a` hold."""
    var n = 0
    if a.child:
        n += _udf_apply_count(a.child.value())
    if a.child1:
        n += _udf_apply_count(a.child1.value())
    if a.child2:
        n += _udf_apply_count(a.child2.value())
    if a.child3:
        n += _udf_apply_count(a.child3.value())
    return n


def _apply_call_spec(
    node: LogicalPlan,
    call: Expr,
    input: Schema,
    inputs: LoweringInputs,
    var out_name: String,
) raises -> UdfCallSpec:
    """The OP_UDF_APPLY spec of `call`, an EXPR_UDF_APPLY over `input`, whose
    result is appended as column `out_name`; or its refusal."""
    var index = _udf_entry(node, inputs, call.udf_apply_index())
    ref u = inputs.udfs[index]
    if (
        u.kind != UDF_REF_KIND_SCALAR
        and u.kind != UDF_REF_KIND_ROW
        and u.kind != UDF_REF_KIND_MAP_BATCHES_COLUMN
    ):
        raise _udf_unserved(
            node,
            "UdfRef "
            + String(index)
            + " is a "
            + udf_ref_kind_name(u.kind)
            + " function, and a call in an expression calls a SCALAR, ROW or"
            " MAP_BATCHES_COLUMN one",
        )
    var n = call.udf_apply_num_args()
    if n != len(u.arg_types):
        raise _udf_unserved(
            node,
            "a call of UdfRef "
            + String(index)
            + " passes "
            + String(n)
            + " arguments, and it declares "
            + String(len(u.arg_types)),
        )
    var reads = List[String]()
    if u.kind == UDF_REF_KIND_ROW:
        reads = _declared_reads(node, u, index, input)
    var args = List[Expr](capacity=n)
    for i in range(n):
        ref arg = call.udf_apply_arg_ref(i)
        if _udf_apply_count(arg) > 0:
            raise _udf_unserved(
                node, "a call of a user function in the argument of another"
            )
        if u.kind == UDF_REF_KIND_ROW:
            _reads_are_declared(
                node, u, index, reads, arg, "argument " + String(i)
            )
        args.append(arg.copy())
    var outs = List[String]()
    outs.append(out_name^)
    return UdfCallSpec(index, u.kind, reads^, args^, outs^)


def _frame_call_spec(
    node: LogicalPlan, inputs: LoweringInputs
) raises -> UdfCallSpec:
    """The OP_UDF_FRAME spec of a PLAN_MAP_BATCHES node, or its refusal."""
    ref d = node.map_batches_data_ref()
    var index = _udf_entry(node, inputs, d.udf_index)
    ref u = inputs.udfs[index]
    _udf_kind_is(node, u, index, UDF_REF_KIND_MAP_BATCHES_FRAME, "a MapBatches node")
    var reads = _declared_reads(node, u, index, d.child[].output_schema)
    for g in range(len(d.group_by)):
        if _udf_apply_count(d.group_by[g]) > 0:
            raise _udf_unserved(
                node, "a call of a user function in a group key"
            )
        _reads_are_declared(
            node, u, index, reads, d.group_by[g], "group key " + String(g)
        )
    if len(d.group_by) > 0:
        raise _udf_unserved(
            node,
            "a grouped frame: no segment gathers each group's rows for one"
            " call yet",
        )
    return UdfCallSpec(
        index, u.kind, reads^, List[Expr](), _names(node.output_schema)
    )


def _step_call_spec(
    node: LogicalPlan, inputs: LoweringInputs
) raises -> UdfCallSpec:
    """The SOURCE_UDF_STEP spec of a PLAN_STEP node, or its refusal."""
    ref d = node.step_data_ref()
    var index = _udf_entry(node, inputs, d.udf_index)
    ref u = inputs.udfs[index]
    _udf_kind_is(node, u, index, UDF_REF_KIND_STEP, "a Step node")
    if len(d.args) != len(u.arg_types):
        raise _udf_unserved(
            node,
            "a Step node passes "
            + String(len(d.args))
            + " literals to UdfRef "
            + String(index)
            + ", which declares "
            + String(len(u.arg_types)),
        )
    return UdfCallSpec(
        index,
        u.kind,
        List[String](),
        List[Expr](),
        _names(node.output_schema),
        d.args.copy(),
    )


def _names(schema: Schema) -> List[String]:
    var out = List[String]()
    for i in range(schema.num_columns()):
        out.append(schema.field_name(i))
    return out^
