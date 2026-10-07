# =============================================================================
# expr_walk — ★ THE Expr TRAVERSALS. ONE COPY EACH, PARAMETERIZED ON A SINK.
# =============================================================================
#
# ⛔ WHY THIS MODULE EXISTS — READ BEFORE ADDING A WALK ANYWHERE ELSE.
#
# An `Expr` walk that exists TWICE (say a "complete" copy under
# the core packages and a second in `the core packages
# compiler_helpers.mojo`) drifts: a new `EXPR_*` tag gets armed in one copy
# and not the other, and the miss is SILENT until it is fatal. Each shape
# below is a real failure of that kind:
#
#   EXPR_WHEN         — projection-pushdown pruned the column used only
#                       inside `when_then_else`
#   EXPR_STRING_OP    — string-only predicates had no descent arm, so the
#                       scan dropped the string column (several TPC-H
#                       queries at once)
#   EXPR_STRING_FN /  — `WHERE upper(v)='C'` decoded a ZERO-column batch and
#   EXPR_WHEN           raised; every CASE projection exported as Arrow type
#                       `null`
#
# The failure mode is the same each time and it is the WORST shape available:
# both walks are `if/elif` ladders whose fall-through is a NO-OP or a `null`
# placeholder, so a missing arm does not raise where the arm is missing — it
# answers "this expression needs no columns" / "this column has no type" and
# the blast lands somewhere else entirely, in a decode or an Arrow export.
#
# ⛔ THIS IS NOT A PACKAGING PROBLEM. The only real difference between the two
# consumers is a DATA-STRUCTURE one: `collect_expr_cols` appends to an ORDERED
# `List[String]` (the parquet late-mat route builds its filter batch's columns
# in exactly that order) and `_collect_expr_columns` adds to a `Set[String]`,
# which has no order. That is a difference in WHERE THE NAMES GO, not in HOW
# THE TREE IS WALKED — so it is a sink, and a sink is a parameter.
#
# ⭐ THE SHAPE IS `ColumnSink` / `SinkKind` FROM
# `komira_arrow/multi_column_builder.mojo`, deliberately: a trait
# with a DEFAULTED `comptime KIND` discriminator, so a third sink can be added
# later without touching a single existing conformer or call site.
#
# ⚠ THE ORDER GUARANTEE IS A COMPILE-TIME FACT, NOT A COMMENT. A caller
# that depends on first-seen order asserts `S.KIND == NameSinkKind.ORDERED`;
# handing it a `UniqueNameSink` is a named compile error instead of a silently
# reordered decode set.
#
# THE GATE: a repository lint pins THIS module's ladders against the declared
# `EXPR_*` tag universe and refuses any re-duplication of a walk into
# `compiler_helpers.mojo`.
# =============================================================================

from std.collections import Set
from std.memory import Pointer

from komira_arrow.schema import Schema, Field
from komira_arrow.arrow_types import ArrowType
# ⚠ `decimal_mul_result_ps_checked`, NOT `decimal_mul_result_ps`. The raising
# presentation of that rule would make this whole walk `raises`, and the walk
# MUST be non-raising — see `walk_expr_field`'s docstring. The rule itself is
# stated once, in `decimal_arith.mojo`.
from komira_scalar_arithmetic.decimal_arith import (
    decimal_add_result_ps,
    decimal_mul_result_ps_checked,
)
from komira_plan_expr.literal_domain import int_literal_fits
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_BETWEEN,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_REGEXP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_UDF_CALL,
    EXPR_EXTRACT,
    EXPR_JSON_EXTRACT,
    _is_trunc_unit,
    string_fn_returns_int,
    string_fn_n_returns_int,
    string_fn_n_returns_float,
    REGEXP_LIKE,
    REGEXP_MATCH,
    REGEXP_REPLACE,
    REGEXP_SPLIT_TO_ARRAY,
    REGEXP_EXTRACT_ALL,
    REGEXP_COUNT,
    REGEXP_INSTR,
    REGEXP_SUBSTR,
    REGEXP_FULL_MATCH,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    UN_ABS,
    UN_SIGN,
    UN_BIT_COUNT,
    UN_TRUNC,
    UN_ROUND,
)


# =============================================================================
# §0 — NameSinkKind — WHICH ordering guarantee a name sink provides
# =============================================================================
#
# Canonical enum shape for this tree (`var _tag: UInt8` + named `comptime`
# constants), the same shape as `SinkKind` / `Purity`. No heap fields, so it
# is legal as a `comptime` trait member.


struct NameSinkKind(ImplicitlyCopyable, Movable, Copyable, Deinitable):
    """What a `ExprNameSink` conformer guarantees about the names it receives.

        ORDERED : first-seen ORDER preserved, duplicates KEPT. The parquet
                  late-mat route depends on this — it decodes the filter
                  batch's columns in exactly the order the walk emitted them.
        UNIQUE  : deduplicated, NO order guarantee. What the optimizer's
                  column-need analysis wants (it only asks "is this column
                  needed").

    ⚠ ORDERED is the DEFAULT because it is the STRONGER promise: a conformer
    that forgets to declare its kind is treated as making the guarantee a
    caller may rely on, and the compile error lands on the conformer that
    lied rather than on the caller that trusted it.
    """

    var _tag: UInt8

    def __init__(out self, tag: UInt8):
        self._tag = tag

    def __init__(out self, tag: Int):
        self._tag = UInt8(tag)

    comptime ORDERED = NameSinkKind(0)
    comptime UNIQUE = NameSinkKind(1)

    def __eq__(self, other: NameSinkKind) -> Bool:
        return self._tag == other._tag

    def __ne__(self, other: NameSinkKind) -> Bool:
        return self._tag != other._tag

    def tag(self) -> UInt8:
        """The raw discriminator."""
        return self._tag


# =============================================================================
# §1 — ExprNameSink — where a column-reference walk puts the names it finds
# =============================================================================


trait ExprNameSink(Movable):
    """An append-only sink for column names discovered by
    `walk_expr_column_refs`.

    The ONLY thing that differs between the two consumers of the
    column-reference walk. Conformers borrow the caller's container through a
    CONCRETE origin (`Pointer[T, origin]`, the `Tracer[origin]` / `ChunkView
    [origin]` shape) so the two public wrappers keep their existing
    `mut out: List[String]` / `mut cols: Set[String]` signatures with no copy
    and no `UnsafePointer`.
    """

    comptime KIND: NameSinkKind = NameSinkKind.ORDERED
    """This sink's ordering guarantee. Defaults to ORDERED — the stronger
    promise — so a conformer must OPT IN to being unordered."""

    def add_name(mut self, name: String):
        """Record one referenced column name.

        Called once per column REFERENCE, not per distinct column: an
        ORDERED sink keeps the duplicates (the caller dedupes if it wants
        to), a UNIQUE sink folds them.
        """
        ...


# =============================================================================
# §2 — OrderedNameSink[origin] — the ORDERED conformer (List[String])
# =============================================================================


struct OrderedNameSink[origin: MutOrigin](ExprNameSink):
    """Appends to a borrowed `List[String]`: first-seen ORDER preserved,
    duplicates KEPT.

    ⛔ THE ORDER IS LOAD-BEARING, WHICH IS WHY THIS SINK EXISTS. The parquet
    LATE-MAT route (`parquet_source.next_morsel` /
    `streaming_late_mat.compute_late_materialization`) decodes EXACTLY the
    names this walk emits, in this order, and then evaluates the decode
    filter over the resulting batch. Reordering them changes the column order
    of a batch that downstream code indexes positionally — a SILENT WRONG
    ANSWER, not a crash, which is why it is pinned by a dedicated test
    (`test_expr_walk_unification.mojo`) and not left to a comment.

    Parameters:
        origin: The mutable origin of the borrowed output list.
    """

    comptime KIND = NameSinkKind.ORDERED

    # CONCRETE-origin borrow of the caller's list. NOT a wildcard origin, NOT
    # `unsafe_from_address=Int` — a `Pointer(to=referent)` of a live ref, the
    # same shape as `Tracer._eng` / `ChunkView._chunk`.
    var _out: Pointer[List[String], Self.origin]

    @always_inline
    def __init__(out self, ref [Self.origin] out: List[String]):
        """Borrow `out` under `Self.origin`."""
        self._out = Pointer(to=out)

    @always_inline
    def add_name(mut self, name: String):
        self._out[].append(name)


@always_inline
def ordered_name_sink[
    o: MutOrigin
](ref [o] out: List[String]) -> OrderedNameSink[o]:
    """Borrow `out` as an ORDERED name sink, inferring its origin.

    The `chunk_view` shape: an explicit factory so the origin parameter is
    inferred from the argument at the call site.
    """
    return OrderedNameSink[o](out)


# =============================================================================
# §2a — UniqueNameSink[origin] — the UNIQUE conformer (Set[String])
# =============================================================================


struct UniqueNameSink[origin: MutOrigin](ExprNameSink):
    """Adds to a borrowed `Set[String]`: deduplicated, NO order guarantee.

    What the optimizer's column-need analysis wants — it asks only whether a
    column is needed, never in what order. Declaring `KIND = UNIQUE` is what
    makes handing this to an order-dependent caller a compile error.

    Parameters:
        origin: The mutable origin of the borrowed output set.
    """

    comptime KIND = NameSinkKind.UNIQUE

    var _out: Pointer[Set[String], Self.origin]

    @always_inline
    def __init__(out self, ref [Self.origin] out: Set[String]):
        """Borrow `out` under `Self.origin`."""
        self._out = Pointer(to=out)

    @always_inline
    def add_name(mut self, name: String):
        self._out[].add(name)


@always_inline
def unique_name_sink[
    o: MutOrigin
](ref [o] out: Set[String]) -> UniqueNameSink[o]:
    """Borrow `out` as a UNIQUE (deduping, unordered) name sink."""
    return UniqueNameSink[o](out)


# =============================================================================
# §3 — walk_expr_column_refs — ★ THE ONE COLUMN-REFERENCE WALK
# =============================================================================


def walk_expr_column_refs[S: ExprNameSink](expr: Expr, mut sink: S):
    """Walk `expr` and hand every referenced column NAME to `sink`.

    ★ THIS IS THE ONLY COLUMN-REFERENCE WALK IN THE TREE.
    `compiler_helpers.collect_expr_cols` (ordered `List`) and
    `plan_helpers._collect_expr_columns` (deduped `Set`) are three-line
    adapters that build a sink and call this.

    ⛔ AN UNDER-COLLECTING ARM IS NOT PESSIMAL, IT IS A CRASH. This ladder's
    fall-through is a NO-OP, so a tag with no arm reports "this expression
    references no columns". Two consumers act on that answer directly:

      * the parquet LATE-MAT route decodes EXACTLY these names before
        evaluating the decode filter, so an under-collect decodes a
        ZERO-COLUMN batch and the predicate dies in `_eval_predicate` with
        `Schema.column_index: no field named '<col>'`;
      * projection-pushdown / column-pruning drops any column referenced
        ONLY under the un-armed tag, so the scan never reads it.

    # DERIVED FACTS — re-derive with the gate, never hand-count.
    # arms: 23
    # unwalked: EXPR_BETWEEN EXPR_COL_IDX EXPR_LITERAL EXPR_SORT_KEY

    `EXPR_COL_IDX` (a column by INDEX — no name to add) and `EXPR_LITERAL`
    (no refs) are TRUE leaves. `EXPR_BETWEEN` / `EXPR_SORT_KEY` carry no
    payload struct in this IR. That is the WHOLE blind spot now, and all four
    members of it are leaves by construction rather than by omission.

    ⭐ DO NOT DEFER AN ARM "UNTIL SOMETHING EXERCISES IT". An un-armed nested
    tag (`EXPR_JSON_EXTRACT`, say) reports the projection as referencing NO
    columns the moment a door can say it, column-pruning drops the parent
    column, and EVERY such query dies with `Schema.column_index: no field
    named '<col>'` — the second of the two consequences listed above.

    Parameters:
        S: The `ExprNameSink` conformer receiving the names.

    Args:
        expr: The expression tree to walk.
        sink: Where the names go.
    """
    if expr.tag == EXPR_COL_REF:
        sink.add_name(expr.col_ref_name())
    elif expr.tag == EXPR_BINARY_OP:
        walk_expr_column_refs(expr.binary_left_ref(), sink)
        walk_expr_column_refs(expr.binary_right_ref(), sink)
    elif expr.tag == EXPR_UNARY_OP:
        walk_expr_column_refs(expr.unary_child_ref(), sink)
    elif expr.tag == EXPR_CAST:
        walk_expr_column_refs(expr.cast_child_ref(), sink)
    elif expr.tag == EXPR_ALIAS:
        walk_expr_column_refs(expr.alias_child_ref(), sink)
    elif expr.tag == EXPR_STRING_OP:
        # `col.contains/.starts_with/.ends_with/.like` — the child is the
        # string column expression; the pattern is a plan-literal. Missing
        # this arm drops string columns (`p_name`, `o_comment`, ...) from
        # TPC-H scan projections.
        walk_expr_column_refs(expr.string_op_child_ref(), sink)
    elif expr.tag == EXPR_WHEN:
        # CASE WHEN ... THEN ... ELSE ... — every case CONDITION and RESULT
        # carries column refs, and so does the default. Missing this arm
        # prunes any column used only inside `when_then_else(...)`.
        ref when_data = expr._when.value()
        for i in range(len(when_data.cases)):
            walk_expr_column_refs(when_data.cases[i].condition[], sink)
            walk_expr_column_refs(when_data.cases[i].result[], sink)
        walk_expr_column_refs(when_data.default[], sink)
    elif expr.tag == EXPR_IN_LIST:
        # Only the child carries column refs; the
        # values are scalar literals.
        walk_expr_column_refs(expr.in_list_child_ref(), sink)
    elif expr.tag == EXPR_JSON_EXTRACT:
        # `json_extract(payload, '$.a')` over a PARQUET scan: without this arm
        # the walk reports NO columns, column-pruning drops `payload` and the
        # query dies in `Schema.column_index: no field named 'payload'`.
        #
        # The PATH is `JsonExtractData.path_segments`, a `List[String]` parsed
        # at plan time — no column refs there. Only the parent carries any.
        walk_expr_column_refs(expr.json_extract_parent_ref(), sink)
    elif expr.tag == EXPR_STRUCT_FIELD:
        # The FIELD NAME is a `String` on the payload,
        # not an Expr; only the parent carries column refs. ⚠ ARMED EVEN
        # IF NO SQL TEXT REACHES THIS TAG (`struct_extract` is
        # refused by the SQL door): an under-collecting arm is a CRASH
        # rather than a pessimization, and the `col("addr").field("city")`
        # DataFrame door already builds this node.
        walk_expr_column_refs(expr.struct_field_parent_ref(), sink)
    elif expr.tag == EXPR_STRUCT_FIELD_IDX:
        # The by-INDEX twin. `field_idx` is an `Int`; only the parent carries
        # refs. Armed together with its by-name sibling deliberately — the two
        # are a documented dual-variant pair, and arming one alone is how a
        # pair drifts.
        walk_expr_column_refs(expr.struct_field_idx_parent_ref(), sink)
    elif expr.tag == EXPR_MAP_GET:
        # ⚠ TWO CHILDREN, NOT ONE, AND THE SECOND IS THE WHOLE POINT OF THE
        # TAG. `MapGetData.key` is a full `Expr` — a Map key is a RUNTIME
        # value, which is what distinguishes Map from Struct — so
        # `map["which"]` may read a second column, and walking only the parent
        # would prune it.
        walk_expr_column_refs(expr.map_get_parent_ref(), sink)
        walk_expr_column_refs(expr.map_get_key_ref(), sink)
    elif expr.tag == EXPR_AGG_FN:
        # Agg-as-expression (scalar broadcast): the `child` is the
        # aggregate's input. Normally consumed by
        # `optimizer_scalar_broadcast` before this walk sees it, but armed
        # so the walk is robust against rule-ordering changes.
        walk_expr_column_refs(expr._agg_fn.value().child[], sink)
    elif expr.tag == EXPR_WINDOW_FN:
        # Window-as-expression. ⚠ THE CHILDREN ARE COLUMN NAMES, NOT Exprs:
        # `arg_col` is the input, `partition_by` / `order_by` are the
        # OVER-clause columns. All three must reach the scan.
        ref wf = expr._window_fn.value()
        if wf.arg_col.byte_length() > 0:
            sink.add_name(wf.arg_col)
        for i in range(len(wf.partition_by)):
            sink.add_name(wf.partition_by[i])
        for i in range(len(wf.order_by)):
            sink.add_name(wf.order_by[i])
    elif expr.tag == EXPR_CORRELATED_SUBQUERY:
        # `outer_refs` are OUTER-scope column names the inner plan
        # correlates with; `in_lhs_col` is the outer column on the LHS of a
        # correlated `IN`. The inner plan's own columns are inner-scope and
        # deliberately NOT added.
        ref cs = expr._corr_subq.value()[]
        for i in range(len(cs.outer_refs)):
            sink.add_name(cs.outer_refs[i])
        if cs.in_lhs_col.byte_length() > 0:
            sink.add_name(cs.in_lhs_col)
    elif expr.tag == EXPR_REGEXP:
        # `regexp_*(s, pattern, ...)` — the `child` is the string column;
        # pattern / replacement / flags / group are plan-literals.
        walk_expr_column_refs(expr._regexp.value().child[], sink)
    elif expr.tag == EXPR_MATH_FN:
        # Unary scalar math (sin/cos/sqrt/...) — one child.
        walk_expr_column_refs(expr.math_fn_child_ref(), sink)
    elif expr.tag == EXPR_MATH_FN2:
        # Binary scalar math (atan2/pow) — both children.
        walk_expr_column_refs(expr.math_fn2_left_ref(), sink)
        walk_expr_column_refs(expr.math_fn2_right_ref(), sink)
    elif expr.tag == EXPR_SUBSTRING:
        # `substring(s, start, length)` — the string child carries the refs;
        # start/length are plan-literals.
        walk_expr_column_refs(expr.substring_child_ref(), sink)
    elif expr.tag == EXPR_STRING_FN:
        # `upper(s)` and its family. THE ARM
        # WHOSE ABSENCE CRASHED `WHERE upper(v) = 'C'`.
        walk_expr_column_refs(expr.string_fn_child_ref(), sink)
    elif expr.tag == EXPR_UDF_CALL:
        # `affine(col("x"))` — the ARGUMENT carries
        # every column ref; the name / handle / dtype tags are plan-literals.
        walk_expr_column_refs(expr.udf_call_child_ref(), sink)
    elif expr.tag == EXPR_STRING_FN_N:
        # `concat(a, b)` / `lpad(s, n, p)` and
        # the rest of the variadic family. EVERY ARGUMENT is an ordinary
        # expression, so every one of them can carry a column ref; there is no
        # plan-literal slot in this payload to skip.
        #
        # ⚠ THE LOOP IS THE ARM. A fixed-arity arm written against the first
        # member someone tries (`concat(a, b)` — two args) collects nothing
        # from `concat(a, b, c)`'s third, and that under-collection is the
        # exact shape this module's header describes: the scan drops the
        # column and the decode dies elsewhere.
        ref sfnn_args = expr._string_fn_n.value().args
        for i in range(len(sfnn_args)):
            walk_expr_column_refs(sfnn_args[i], sink)
    elif expr.tag == EXPR_EXTRACT:
        # `year(d)` / `date_trunc(u, d)`.
        # The `child` carries every column ref; the UNIT is a plan-literal.
        #
        # ★★ Without this arm `SELECT year(d) FROM read_parquet(...)` decodes a
        # batch with no `d` in it and dies with `Schema.column_index: no field
        # named 'd'` — the exact sentence the docstring says an
        # under-collecting arm produces.
        #
        # ⚠ AND IT IS NOT SQL-ONLY. The projection-pushdown consumer does not
        # know which door authored the plan, so `col('d').year()` over a
        # PARQUET scan fails identically; a test that feeds an IN-MEMORY
        # source cannot see it, because that source prunes nothing.
        walk_expr_column_refs(expr.extract_child_ref(), sink)
    # Unwalked tags are enumerated in the derived-facts block above and pinned
    # by a repository lint. There is no second copy to keep in sync — that is
    # the point of this module.


# =============================================================================
# §4 — ColRefFieldPolicy — the ONE deliberate difference between the two
#      field-inference entry points
# =============================================================================
#
# `compiler_helpers.field_for_expr` and `logical_plan._infer_expr_field`
# differ on exactly ONE arm, on purpose, and agree on everything else:
#
#  1. EXPR_COL_REF, MISSING COLUMN — DELIBERATE AND COMPILER-ENFORCED
#     (`_infer_expr_field` is a non-raising `def`).
#     `field_for_expr` resolves through `Schema.column_index`, which RAISES.
#     `_infer_expr_field` returns a `Field(name, NULL, True)` PLACEHOLDER for
#     the plan validator to catch later with a better message. Those are two
#     genuinely different jobs — one runs INSIDE an operator where a missing
#     column is unrecoverable, the other runs at PLAN-BUILD time where the
#     validator owns the diagnostic — so this parameterizes rather than
#     merges. It is the whole reason this trait exists.
#
#  2. COMPARISON BinaryOp TYPE — ⛔ NOT A DIFFERENCE. Both return BOOL for
#     BIN_EQ/NE/LT/LE/GT/GE/AND/OR (§5). Falling through to the LEFT
#     operand's type instead would label `str_col = 'X'` STRING, and would
#     make an INTERVAL_MDN BIN_EQ/BIN_NE column (which `_eval_column_expr`
#     returns as `Column.from_boolean(...)`) carry a BOOL column under a field
#     declaring INTERVAL_MDN — the schema-contradicts-its-own-data shape that
#     the Arrow C-ABI export refuses.


trait ColRefFieldPolicy:
    """How `walk_expr_field` builds the Field for an `EXPR_COL_REF` — the one
    arm whose two entry points differ ON PURPOSE.

    ⛔ NON-RAISING, AND THAT IS FORCED BY THE CALLERS, NOT A PREFERENCE. See
    `walk_expr_field`. The missing-column case is reported through the
    `missing` out-parameter and RAISED BY THE ADAPTER that wants it raised —
    which is what lets one shared ladder serve both a raising and a
    non-raising entry point.

    Stateless: a policy is a comptime tag selecting one arm body, never a
    value that is constructed or carried.
    """

    @staticmethod
    def col_ref_field(
        name: String, schema: Schema, mut missing: String
    ) -> Field:
        """The output Field for a bare column reference named `name`.

        On a column that is NOT in `schema`, record `name` in `missing` (only
        if `missing` is still empty — FIRST miss wins, so the reported column
        is the leftmost one, which is the one a reader looks for) and return a
        NULL placeholder.
        """
        ...


struct ExecColRefFields(ColRefFieldPolicy):
    """EXECUTION-TIME policy: the FULL metadata clone.

    Used by `compiler_helpers.field_for_expr`, i.e. by `MapOp.execute` /
    `op_chain_adapter` / `streaming_ops` — operators naming the type of a
    column they have just computed over a real batch.

    Resolves through `Schema.field_at_unchecked`, which reconstructs
    everything: decimal (p,s), `_tz`, `_dict_index_type`, `_union_type_ids`,
    `_flags`, per-field kv metadata, the stored `dtype`, and nested children.

    ⚠ `field_at_unchecked`, NOT `field_at`: the checked form raises, which
    would make the whole walk raising. The bounds precondition it asks the
    caller to assert is discharged by the linear scan immediately above the
    call — `i` comes from `range(schema.num_columns())`.
    """

    @staticmethod
    def col_ref_field(
        name: String, schema: Schema, mut missing: String
    ) -> Field:
        for i in range(schema.num_columns()):
            if schema.field_name(i) == name:
                return schema.field_at_unchecked(i)
        if missing.byte_length() == 0:
            missing = name
        return Field(name, ArrowType.NULL, True)


struct PlanColRefFields(ColRefFieldPolicy):
    """PLAN-BUILD-TIME policy: the narrower clone the plan side has always
    built.

    ⚠ DELIBERATELY NOT `field_at_unchecked`, EVEN THOUGH THAT IS RICHER.
    `field_at_unchecked` also restores the schema's STORED `dtype` slot, which
    `SchemaBuilder` fills from whatever Field the caller handed it and which
    can legitimately disagree with `arrow_type`. EVERY plan node's
    `output_schema` is synthesized through this arm, so changing which `dtype`
    they carry is a behaviour change with a wide blast radius.

    ⚠ `_tz` IS COPIED. It is the one PARAMETERISED slot a narrow copy could
    omit, and omitting it is a wrong answer rather than a narrower one —
    `timestamp_us_utc` is not
    its own `ArrowType`, so dropping `_tz` changes the declared TYPE and not
    just its metadata. The inline comment at the copy carries the argument.
    ⇒ When adding a slot here, the test is "can the type be reconstructed
    without it", not "is it in the sibling policy".
    """

    @staticmethod
    def col_ref_field(
        name: String, schema: Schema, mut missing: String
    ) -> Field:
        for i in range(schema.num_columns()):
            if schema.field_name(i) == name:
                var f = Field(
                    schema.field_name(i),
                    schema.field_arrow_type(i),
                    schema.field_nullable(i),
                )
                f.decimal_precision = schema.field_decimal_precision(i)
                f.decimal_scale = schema.field_decimal_scale(i)
                # ⭐⭐ `_tz` IS NOT COSMETIC —
                # `timestamp_us_utc` IS NOT ITS OWN `ArrowType`. A UTC
                # timestamp and a naive one are BOTH
                # `ArrowType.TIMESTAMP_US`, discriminated ONLY by this slot,
                # so without it a `col_ref` over a tz-aware column resolves to
                # a field that DECLARES A DIFFERENT TYPE than its source.
                # Since EVERY plan node's `output_schema` is synthesized
                # through this one arm (see `walk_expr_field`), a plain
                # `SELECT t` over a tz-aware column would declare a NAIVE
                # timestamp while the executor delivered a tz-aware one —
                # two authorities, one question.
                #
                # ⚠ NOT COSMETIC AT THE WIRE EITHER. Arrow's
                # `Timestamp(unit, tz=None)` and `Timestamp(unit, tz="UTC")`
                # are DIFFERENT types in `Schema.fbs` and different C Data
                # Interface format strings (`tsu:` vs `tsu:UTC`). A consumer
                # reading `tsu:` treats the ticks as a local wall clock with
                # NO instant attached, so every row means a different moment
                # depending on the reader's session zone.
                #
                # ⛔ AND THE FIX IS DELIBERATELY *NOT* "SWITCH TO
                # `field_at_unchecked`", which the header above already
                # argues against: that form also restores the schema's
                # STORED `dtype` slot, whose blast radius is every plan
                # node's output schema. Copying the ONE missing parameter is
                # the subset that changes nothing else. A copy, never a mint
                # — stamping "UTC" because the type is a timestamp is the
                # mirror-image wrong answer, and the corpus has cells for
                # both a naive `timestamp_us` and a `timestamp_us_utc`.
                f._tz = schema.field_tz(i)
                # Propagate nested
                # children for STRUCT (or future MAP/LIST/UNION), required so
                # the EXPR_STRUCT_FIELD arms can resolve the projected child
                # Field through `parent_field._child_*`.
                var n_ch = schema.field_num_children(i)
                for j in range(n_ch):
                    f.add_child(
                        schema.field_child_name(i, j),
                        schema.field_child_arrow_type(i, j),
                        schema.field_child_nullable(i, j),
                    )
                return f^
        if missing.byte_length() == 0:
            missing = name
        # Column not found — placeholder. ⚠ The plan-side ADAPTER discards
        # `missing` on purpose; the plan VALIDATOR owns that diagnostic.
        return Field(name, ArrowType.NULL, True)


# =============================================================================
# §5 — walk_expr_field — ★ THE ONE OUTPUT-FIELD INFERENCE
# =============================================================================


def walk_expr_field[P: ColRefFieldPolicy](
    expr: Expr, schema: Schema, mut missing: String
) -> Field:
    """Infer the output `Field` for `expr` given a parent `schema`.

    ★ THIS IS THE ONLY OUTPUT-FIELD INFERENCE IN THE TREE.
    `compiler_helpers.field_for_expr` and `logical_plan._infer_expr_field`
    are one-line adapters selecting a `ColRefFieldPolicy`.

    ⛔ THIS FUNCTION IS NON-RAISING, AND THAT IS A HARD CONSTRAINT, NOT A
    STYLE CHOICE. `LogicalPlan.project`, `.project_with_udf`, `.aggregate`
    and `.aggregate_with_udf` are NON-RAISING CONSTRUCTORS that synthesize
    their `output_schema` through `_infer_expr_field`, which therefore cannot
    raise either. Mojo's effect system is per-function, so ONE call to a
    `raises` callee here would make this walk raising and those four plan
    constructors with it — and they are called from the SDK, the SQL binder
    and dozens of optimizer passes. Two consequences, both load-bearing:

      * the missing-column case is REPORTED through `missing`, not raised;
        `compiler_helpers.field_for_expr` turns a non-empty `missing` into
        the raise its callers expect, and `_infer_expr_field` discards it.
        That is what lets ONE ladder serve a raising and a non-raising entry
        point without a second copy.
      * the decimal-mul rule is reached through
        `decimal_mul_result_ps_checked`, the non-raising core of
        `decimal_mul_result_ps`. Re-deriving `min(p1+p2+1,38)` / `s1+s2` here
        instead would have been a second copy of that rule — this module's
        whole reason for existing, reintroduced two files away.

    ⭐ THE COMPILER CERTIFIES THE DELIBERATE DIFFERENCE. The missing-column
    difference is not merely documented intent, it is enforced —
    `_infer_expr_field` is a non-raising `def` and `field_for_expr` is
    `raises`, and the build fails if either changes. (The comparison
    BinaryOp type is NOT a difference; see §4.)

    ⛔ THE `else` BELOW RETURNS `ArrowType.NULL`, AND THAT IS AN UNEXPORTABLE
    COLUMN, NOT A PLACEHOLDER. `MapOp.execute` evaluates a computed
    projection's DATA with `_eval_column_expr` (a THIRD ladder, which has its
    own arms) and names its TYPE with this function. A tag armed there and
    not here produces a batch whose data is CORRECT and whose schema says
    `null`, and the Arrow C-ABI export then refuses the whole result with

        UnsupportedArrowCABIType: Arrow type 'null' (export)

    MEASURED: one missing arm makes EVERY CASE projection fail over EVERY
    column type including int64. ⭐ THE DIAGNOSTIC TELL: the zero-row
    variants PASS, because an empty result takes
    `materialize_parquet_collect`'s `empty_out_schema` recovery, which does
    not come through here. If a projection is green on `empty` and red on
    everything else, it is this function.

    # DERIVED FACTS — re-derive with the gate, never hand-count.
    # arms: 22
    # unwalked: EXPR_AGG_FN EXPR_COL_IDX EXPR_CORRELATED_SUBQUERY EXPR_SORT_KEY EXPR_WINDOW_FN

    Every member of the unwalked set still lands on the `null` fallback and
    is therefore unexportable in a projection.

    ⛔ `EXPR_AGG_FN` IS THE ONE RESIDUAL THAT `_eval_column_expr` CAN
    PRODUCE AND THIS LADDER CANNOT TYPE, and it is blocked for an
    ARCHITECTURAL reason rather than an unwritten one: the authority on an
    aggregate's output Field is `logical_plan._infer_agg_field`, and
    `logical_plan` already imports THIS module, so reaching it from here
    closes a real cycle. Lifting `_infer_agg_field` into a leaf module is
    the fix. The gate pins this residual at exactly {EXPR_AGG_FN} and
    goes RED if it GROWS, so the next tag cannot join it quietly.

    `EXPR_COL_IDX` / `EXPR_SORT_KEY` / `EXPR_CORRELATED_SUBQUERY` /
    `EXPR_WINDOW_FN` are not reachable in a projection the executor
    evaluates — the first two carry no payload and the last two are lowered
    away by the optimizer before a projection sees them.

    Parameters:
        P: The `EXPR_COL_REF` resolution policy — the one deliberate
            difference between the two entry points (see §4).

    Args:
        expr: The expression to infer an output Field for.
        schema: The input schema the expression is evaluated against.
    """
    if expr.tag == EXPR_COL_REF:
        return P.col_ref_field(expr.col_ref_name(), schema, missing)

    elif expr.tag == EXPR_ALIAS:
        var alias_name = expr.alias_name()
        var child_field = walk_expr_field[P](expr.alias_child_ref(), schema, missing)
        # An alias renames the
        # field but preserves ALL of the child field's Arrow type metadata —
        # decimal (p,s), `_tz`, `_dict_index_type`, `_union_type_ids`,
        # `_flags`, kv-metadata, nested children. Rebuilding via the bare
        # 3-arg ctor silently drops tz on the alias, which surfaces as a
        # tz-less output schema when a SQL query AS-renames a `TIMESTAMP WITH
        # TIME ZONE` column (and a decimal-only rebuild drops nested children
        # too).
        child_field.name = alias_name
        return child_field^

    elif expr.tag == EXPR_LITERAL:
        var sv = expr.literal_value()
        if sv.is_decimal128():
            var fd = Field("literal", ArrowType.DECIMAL128, False)
            fd.decimal_precision = (
                sv.dec128_precision if sv.dec128_precision > 0 else 38
            )
            fd.decimal_scale = sv.dec128_scale
            return fd^
        if sv.is_string():
            # ★★ THE STRING ARM — THE TWO HALVES OF THE ENGINE MUST AGREE.
            # `compiler_helpers.broadcast_scalar` carries a STRING literal
            # as a `StringArray` (arrow id 13). A string `ScalarValue` is
            # discriminated by `_kind == SCALAR_KIND_STRING` and leaves `dtype`
            # at `DTYPE_NONE`, so the `from_dtype` call below would map it to
            # `ArrowType.NULL` (arrow id 0) — `from_dtype`'s `else`.
            #
            # ⇒ Without this arm `SELECT 'duckdb' AS cs` DECLARES a NULL
            # column and BUILDS a STRING one:
            #   PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED: PLAN_PROJECT ...
            #   derived=[cs:0:-, v:5:N] wire=[cs:13:-, v:5:N]
            #
            # ⚠ IT MUST BE TESTED BEFORE THE `is_null()` READ BELOW AND NOT
            # AFTER: `is_null()` is `_kind == SCALAR_KIND_DTYPE && dtype ==
            # DTYPE_NONE`, so a string is NOT null by it — but `from_dtype`
            # never sees a `_kind` at all, so ordering this arm after the
            # `at` computation would leave the bug intact for every string.
            #
            # ⚠ NULLABILITY IS `False`, matching every other literal here and
            # matching `broadcast_scalar`'s non-nullable `StringArray`.
            return Field("literal", ArrowType.STRING, False)
        # A typed NULL now
        # carries `dtype == DTYPE_NONE`; its declared logical type lives in
        # `null_type()`. Read it so a null-literal keeps its column type.
        #
        # ★★ THE DATE32 / TIMESTAMP ARMS — THE DECLARER HALF.
        # `compiler_helpers.broadcast_scalar` has matching `is_date32()` /
        # `is_timestamp()` arms, and the two must move TOGETHER. Declaring a
        # DATE32's real type while the materializer produced an INT64 column
        # would turn a matched pair of wrong answers (declared NULL, produced
        # int64 zeros — silently REPAIRED toward the schema) into a hard
        # `RecordBatch.column_arrow_type: PHYSICAL LAYOUT CONFLICT`.
        # Falsifiers: `test_plan_wire_value_literal_rows`
        # (both halves, plan door) and `test_sql_temporal_expression_output` (SQL door, end to end).
        #
        # ⚠ TIMESTAMP_US, matching `broadcast_scalar`'s arm: `ScalarValue`
        # holds ONE timestamp member (`ts_micros`), so there is no unit to
        # choose. The two sides must name the SAME ArrowType or the pair is
        # broken again in the other direction.
        if sv.is_date32():
            return Field("literal", ArrowType.DATE32, False)
        if sv.is_timestamp():
            return Field("literal", ArrowType.TIMESTAMP_US, False)
        # ⚠ AND THE REMAINING `_kind`-TAGGED KINDS STILL LAND ON
        # `ArrowType.NULL` HERE, DELIBERATELY UNFIXED: TIME, DURATION,
        # INTERVAL, DECIMAL256 and BINARY all leave `dtype` at its default, and
        # `broadcast_scalar` has no arm for any of them either — so declaring
        # their real type would turn a matched pair of wrong answers into a
        # PHYSICAL LAYOUT CONFLICT. The pair is fixed at the MATERIALIZER
        # first, then here. `test_plan_wire_value_literal_rows` measures both
        # halves and is the falsifier for either move.
        var at = ArrowType.from_dtype(
            sv.null_type() if sv.is_null() else sv.dtype
        )
        return Field("literal", at, False)

    elif expr.tag == EXPR_BINARY_OP:
        # ⛔ COMPARISON AND BOOLEAN OPS ARE BOOL, WHATEVER THEIR OPERANDS.
        # See §4 note 2. Returning the
        # left operand's type here would mislabel `str_col = 'X'` as STRING
        # (lowering a CSE-projection column with the wrong runtime_dtype),
        # and mislabel the INTERVAL_MDN eq/ne columns that
        # `_eval_column_expr` really does return as BOOL.
        var bop = expr.binary_op()
        if (
            bop == BIN_EQ
            or bop == BIN_NE
            or bop == BIN_LT
            or bop == BIN_LE
            or bop == BIN_GT
            or bop == BIN_GE
            or bop == BIN_AND
            or bop == BIN_OR
        ):
            return Field("expr", ArrowType.BOOL, True)

        var left_field = walk_expr_field[P](expr.binary_left_ref(), schema, missing)
        var right_field = walk_expr_field[P](expr.binary_right_ref(), schema, missing)

        # Componentwise
        # INTERVAL_MDN +/- INTERVAL_MDN -> INTERVAL_MDN. No (p,s) metadata to
        # propagate; the result inherits nullability from the left field (the
        # eval kernel does the actual validity-AND). eq/ne already returned
        # BOOL above; no other op is defined on this type (no calendar-free
        # ordering), so anything else falls to the generic path and the
        # eval-side dispatcher raises.
        if (
            left_field.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO
            and right_field.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO
        ):
            if bop == BIN_ADD or bop == BIN_SUB:
                return Field(
                    "expr", ArrowType.INTERVAL_MONTH_DAY_NANO, True
                )

        # decimal {+,-,*,/} decimal — compute (p,s).
        if (
            left_field.arrow_type == ArrowType.DECIMAL128
            and right_field.arrow_type == ArrowType.DECIMAL128
        ):
            var rp: Int
            var rs: Int
            if bop == BIN_ADD or bop == BIN_SUB:
                var ps = decimal_add_result_ps(
                    left_field.decimal_precision,
                    left_field.decimal_scale,
                    right_field.decimal_precision,
                    right_field.decimal_scale,
                )
                rp = ps[0]
                rs = ps[1]
            elif bop == BIN_MUL:
                # ⚠ THE `_checked` CORE, because this walk cannot raise. An
                # unrepresentable scale (s1+s2 > 38) is reported by the third
                # tuple slot; the DECLARED type is informational here (the
                # engine recomputes precisely and raises at evaluation), so
                # the walk reports the clamped rule rather than inventing a
                # different answer.
                var ps = decimal_mul_result_ps_checked(
                    left_field.decimal_precision,
                    left_field.decimal_scale,
                    right_field.decimal_precision,
                    right_field.decimal_scale,
                )
                rp = ps[0]
                rs = ps[1]
            elif bop == BIN_DIV:
                # ⛔ DECIMAL / DECIMAL IS DOUBLE: DuckDB 1.5.3's type, and what
                # `compiler_eval_column._eval_decimal_binary_pair`
                # produces. A Hive-style (s1 + 4) decimal quotient would
                # answer 29.285714 for DuckDB's 29.28571428571429.
                return Field("expr", ArrowType.FLOAT64, True)
            else:
                # BIN_MOD is the only residual: every comparison left this
                # ladder at the top and ADD/SUB/MUL/DIV are handled above.
                # Keep the LEFT operand's (p,s) — `a % b` cannot exceed the
                # magnitude of `a`. ⚠ NOT `ArrowType.NULL` and not BOOL:
                # BOOL over a decimal remainder is a schema that contradicts
                # its own column.
                rp = left_field.decimal_precision
                rs = left_field.decimal_scale
            var fd = Field("expr", ArrowType.DECIMAL128, True)
            fd.decimal_precision = rp
            fd.decimal_scale = rs
            return fd^

        # Decimal/float -> float64; decimal/int64 -> per op, below; any other
        # decimal/int pairing keeps the decimal side's (p,s) (the evaluator
        # refuses those pairings today). ⚠ NOT "informational": the executed
        # batch is stamped with the field this returns.
        if (
            left_field.arrow_type == ArrowType.DECIMAL128
            or right_field.arrow_type == ArrowType.DECIMAL128
        ):
            if (
                left_field.arrow_type == ArrowType.FLOAT64
                or right_field.arrow_type == ArrowType.FLOAT64
            ):
                return Field("expr", ArrowType.FLOAT64, True)
            var dp = (
                left_field.decimal_precision
                if left_field.arrow_type == ArrowType.DECIMAL128
                else right_field.decimal_precision
            )
            var ds = (
                left_field.decimal_scale
                if left_field.arrow_type == ArrowType.DECIMAL128
                else right_field.decimal_scale
            )
            # ⛔ DECIMAL (op) INT64 COLUMN. The batch is STAMPED with this
            # field: declaring the decimal side's (p, s) for every op would
            # relabel the engine's `*` product (scale s1+s1) and `/` quotient
            # (scale s+4) as scale s1 -- x100 and x10^4, silently. Stated per
            # op, in the exact (p, s) `compiler_eval_column`'s mixed arm produces,
            # which is DuckDB 1.5.3's shape: `/` is DOUBLE; `*` takes the
            # BIGINT as DECIMAL(19, 0) (scale s1); `+ -` align at s1 with the
            # BIGINT's 19 integer digits (`dc(12,2) + bigint` = DECIMAL(22,2),
            # DuckDB's own answer). ⚠ `*`'s precision follows THIS engine's
            # rule (`min(p1 + p2 + 1, 38)`: 32 where DuckDB says 31) -- the
            # value and scale are exact; the precision is the residual.
            var other_t = (
                right_field.arrow_type
                if left_field.arrow_type == ArrowType.DECIMAL128
                else left_field.arrow_type
            )
            if other_t == ArrowType.INT64:
                if bop == BIN_DIV:
                    return Field("expr", ArrowType.FLOAT64, True)
                if bop == BIN_MUL:
                    var mps = decimal_mul_result_ps_checked(dp, ds, 19, 0)
                    var fm = Field("expr", ArrowType.DECIMAL128, True)
                    fm.decimal_precision = mps[0]
                    fm.decimal_scale = mps[1]
                    return fm^
                if bop == BIN_ADD or bop == BIN_SUB:
                    var aps = decimal_add_result_ps(dp, ds, 19 + ds, ds)
                    var fa = Field("expr", ArrowType.DECIMAL128, True)
                    fa.decimal_precision = aps[0]
                    fa.decimal_scale = aps[1]
                    return fa^
            var fd = Field("expr", ArrowType.DECIMAL128, True)
            fd.decimal_precision = dp
            fd.decimal_scale = ds
            return fd^

        # Type promotion: if either side is float64, the result is float64.
        # Mirrors the column per-node promotion and the lowering's
        # `_infer_runtime_dtype`; without it a streaming NoBreaker emit loop
        # dispatches an EXPR_*_F64 RuntimeExpr tree to the i64 view-evaluator.
        var result_type = left_field.arrow_type
        if (
            left_field.arrow_type == ArrowType.FLOAT64
            or right_field.arrow_type == ArrowType.FLOAT64
        ):
            result_type = ArrowType.FLOAT64

        # The integer twin
        # of the float promotion above. `compiler_eval_column
        # ._eval_binary_col_scalar` evaluates `int32_col <arith> <int literal
        # outside int32 range>` at INT64 width, because narrowing the literal
        # to the column would keep its LOW 32 BITS and answer a different
        # question. The DECLARED type has to promote with the executor or the
        # emitted batch's schema contradicts its own column, and a consumer
        # calling `as_primitive[DType.int32]` raises "arrow_type mismatch".
        # Keyed on THE SAME PREDICATE the executor uses (`int_literal_fits`),
        # not on a re-derived bound. ARITHMETIC ONLY — the comparisons left
        # this ladder at the top.
        if (
            result_type == ArrowType.INT32
            and expr.binary_right_ref().tag == EXPR_LITERAL
        ):
            if (
                bop == BIN_ADD
                or bop == BIN_SUB
                or bop == BIN_MUL
                or bop == BIN_DIV
            ):
                var rsv = expr.binary_right_ref().literal_value()
                if rsv.is_int() and not int_literal_fits[DType.int32](
                    rsv.int_val
                ):
                    result_type = ArrowType.INT64
        return Field("expr", result_type, True)

    elif expr.tag == EXPR_UNARY_OP:
        # ★ `EXPR_UNARY_OP` IS ARMED. Without it `NOT x` / `-x` / `x IS NULL`
        # in a projection would land on the `null` fallback and be
        # unexportable by exactly the mechanism in this function's docstring.
        #
        # The type is PER-OP, like EXPR_STRING_FN and unlike EXPR_MATH_FN:
        #   NOT / IS NULL / IS NOT NULL -> BOOL
        #   NEGATE / ABS / TRUNC / ROUND -> the child's own type
        #   SIGN                         -> INT8, whatever the child is
        var uop = expr.unary_op()
        if uop == UN_NOT:
            return Field("not", ArrowType.BOOL, True)
        if uop == UN_SIGN:
            # ★ THE ONE MEMBER OF THIS SPACE WHOSE
            # TYPE IS NEITHER BOOL NOR THE CHILD'S. DuckDB v1.5.3 declares
            # TINYINT for ALL TWELVE of `sign`'s overloads (measured off
            # `duckdb_functions()`, not read off a docs page), so the answer
            # does not depend on the operand at all — `sign(DOUBLE)` is
            # TINYINT exactly as `sign(BIGINT)` is.
            #
            # ⚠ NULLABLE `True` even over a non-nullable child: the kernel
            # propagates the operand's validity, and a nullable field over a
            # column with no nulls is always sound while the converse is the
            # schema-disagrees-with-its-own-column bug.
            return Field("sign", ArrowType.INT8, True)
        if uop == UN_BIT_COUNT:
            # ★ THE SECOND MEMBER WHOSE TYPE IS
            # NEITHER BOOL NOR THE CHILD'S, and it takes `UN_SIGN`'s rule
            # rather than a new one: DuckDB v1.5.3 declares TINYINT for all
            # FIVE integer overloads of `bit_count` (measured off
            # `duckdb_functions()`). The operand's WIDTH changes the VALUE —
            # `bit_count((-1)::INTEGER)` is 32, `::BIGINT` is 64 — but never
            # the TYPE, so this arm does not recurse into the child.
            #
            # ⚠ The eval arm RAISES over a FLOAT operand (DuckDB has no
            # floating overload at all), so this INT8 is the type of every
            # `bit_count` this engine will actually compute.
            return Field("bit_count", ArrowType.INT8, True)
        if uop == UN_IS_NULL:
            # ⚠ NON-NULLABLE, deliberately, and the ONE arm here where that
            # is true of a nullable input: `x IS NULL` is total — it answers
            # true/false for a NULL `x` as readily as for a present one, so
            # the output has no null slot to declare.
            return Field("is_null", ArrowType.BOOL, False)
        if uop == UN_IS_NOT_NULL:
            return Field("is_not_null", ArrowType.BOOL, False)
        # ★ THE TYPE-PRESERVING TAIL — UN_NEGATE / UN_ABS / UN_TRUNC /
        # UN_ROUND. `-x`, `abs(x)`, `trunc(x)` and `round(x)` all return the
        # OPERAND's type and nullability, which is the rule DuckDB v1.5.3
        # states for every one of their numeric overloads and the rule
        # `EXPR_MATH_FN` structurally cannot express (that tag is always
        # FLOAT64 — see the note on `UN_ABS` in `expr.mojo`).
        #
        # ⚠ ONE RECURSION, NOT FOUR. The child's Field is read ONCE and its
        # `arrow_type`/`nullable` reused, so the day a fifth type-preserving
        # member lands it inherits the rule by falling through here rather
        # than by a copied leg that can disagree.
        #
        # ⚠ THE NAME IS SPELLED INLINE AT FOUR RETURNS RATHER THAN SELECTED
        # INTO A `var`. Selecting among string literals is the shape a
        # repository lint keeps out of a linked artifact — it lowers to two
        # independently-relocated constant tables, and a shared library can
        # bind such a pair CROSSED. The verbosity is the point.
        var pres_child = walk_expr_field[P](expr.unary_child_ref(), schema, missing)
        if uop == UN_ABS:
            return Field("abs", pres_child.arrow_type, pres_child.nullable)
        if uop == UN_TRUNC:
            return Field("trunc", pres_child.arrow_type, pres_child.nullable)
        if uop == UN_ROUND:
            return Field("round", pres_child.arrow_type, pres_child.nullable)
        return Field("neg", pres_child.arrow_type, pres_child.nullable)

    elif expr.tag == EXPR_CAST:
        var child_field = walk_expr_field[P](expr.cast_child_ref(), schema, missing)
        if expr.cast_target_arrow() == ArrowType.DECIMAL128:
            var fd = Field(
                child_field.name,
                ArrowType.DECIMAL128,
                # ⚠ SAME `or cast_is_try()` AS THE GENERAL ARM BELOW, AND IT IS
                # HERE FOR THE SAME REASON RATHER THAN BY SYMMETRY: a TRY_CAST
                # to DECIMAL is a node `Expr.cast_from_parts` can build and the
                # wire decoder does build, so this branch is reachable with the
                # flag set even though no SQL spelling produces one.
                child_field.nullable or expr.cast_is_try(),
            )
            fd.decimal_precision = expr.cast_decimal_precision()
            fd.decimal_scale = expr.cast_decimal_scale()
            return fd^
        var target_at = expr.cast_target_arrow()
        # ⛔⛔ `or expr.cast_is_try()` — A TRY_CAST IS NULLABLE WHATEVER ITS CHILD
        # IS; WITHOUT THIS LINE IT WOULD BE DECLARED NON-NULLABLE WHILE PRODUCING
        # NULLS. The whole contract of TRY is to answer NULL where the strict
        # cast would RAISE, so its output carries nulls that its input does
        # not. `_bound_expr_is_string` admits a string LITERAL, which is
        # non-nullable, so `TRY_CAST('abc' AS BIGINT)` reaches this arm with a
        # non-nullable child and answers NULL — the shape
        # `test_s1_carve_outs.test_try_cast_string_bad_input_nulls_e2e`
        # executes over an all-non-null column.
        #
        # ⚠ A DECLARED TYPE THAT DISAGREES WITH THE DATA IS NOT COSMETIC HERE.
        # Downstream arms switch on `Field.nullable` to pick a kernel and to
        # decide whether to allocate a validity bitmap at all; "non-nullable"
        # is a licence to skip the null check, so the wrong answer it produces
        # is a garbage NUMBER rather than an error.
        #
        # ⭐ WIDENING ONLY, WHICH IS WHY IT IS SAFE HERE RATHER THAN AT
        # EACH CALLER: `cast_is_try()` is False for every strict cast, so every
        # strict cast keeps its child-derived nullability.
        return Field(
            child_field.name,
            target_at,
            child_field.nullable or expr.cast_is_try(),
        )

    elif expr.tag == EXPR_REGEXP:
        # regexp_like / regexp_full_match -> Bool; regexp_extract / replace /
        # substr -> Utf8; regexp_count / instr -> Int64; regexp_match /
        # split_to_array / extract_all -> List<Utf8>.
        var rxop = expr.regexp_op()
        if rxop == REGEXP_LIKE:
            return Field("regexp_like", ArrowType.BOOL, True)
        if rxop == REGEXP_FULL_MATCH:
            return Field("regexp_full_match", ArrowType.BOOL, True)
        if rxop == REGEXP_MATCH:
            return Field.list_of_string("regexp_match", True)
        if rxop == REGEXP_SPLIT_TO_ARRAY:
            return Field.list_of_string("regexp_split", True)
        if rxop == REGEXP_EXTRACT_ALL:
            return Field.list_of_string("regexp_extract_all", True)
        if rxop == REGEXP_REPLACE:
            return Field("regexp_replace", ArrowType.STRING, True)
        if rxop == REGEXP_SUBSTR:
            return Field("regexp_substr", ArrowType.STRING, True)
        if rxop == REGEXP_COUNT:
            return Field("regexp_count", ArrowType.INT64, True)
        if rxop == REGEXP_INSTR:
            return Field("regexp_instr", ArrowType.INT64, True)
        return Field("regexp", ArrowType.STRING, True)

    elif expr.tag == EXPR_WHEN:
        # A CASE's type is the FIRST `THEN` clause's — a CASE is NOT a
        # predicate, so this is not Bool; the Bool is one level down in the
        # condition. THE ARM WHOSE ABSENCE MADE EVERY `proj_case_*` CELL
        # UNEXPORTABLE.
        if len(expr._when.value().cases) > 0:
            var first_result = walk_expr_field[P](
                expr._when.value().cases[0].result[], schema, missing
            )
            return Field("case", first_result.arrow_type, True)
        var default_field = walk_expr_field[P](
            expr._when.value().default[], schema, missing
        )
        return Field("case", default_field.arrow_type, True)

    elif expr.tag == EXPR_STRING_OP:
        # `contains` / `starts_with` / `ends_with` / `like` — always BOOL.
        #
        # ⚠ NULLABLE. `False` would be defensible only in PREDICATE context,
        # where an unknown never selects and the mask carries no validity. In
        # PROJECTION context DuckDB v1.5.3 answers NULL for
        # `starts_with(NULL,'he')` and `starts_with('hello',NULL)`, and this
        # engine's projection arm (`_eval_column_expr`) propagates the child's
        # validity to match — so the DATA has nulls, and the declared TYPE must
        # allow them. `MapOp.execute` pairs those two, which is precisely the
        # mismatch `test_projection_type_matches_data.mojo` exists to catch.
        #
        # Its two siblings on the same "a predicate reached a projection"
        # route — `EXPR_IN_LIST` and `EXPR_BETWEEN`, both declared just below
        # — are nullable too.
        return Field("str_op", ArrowType.BOOL, True)

    elif expr.tag == EXPR_IN_LIST:
        # `col IN (...)` is a boolean predicate. The raw node reaches here
        # when CSE hoists a duplicated IN-list subtree into a synthetic
        # projection; without this arm it would fall through to NULL ->
        # runtime_dtype=-1.
        return Field("in_list", ArrowType.BOOL, True)

    elif expr.tag == EXPR_BETWEEN:
        # Same NULL-fallthrough hazard as EXPR_IN_LIST for a CSE-hoisted
        # BETWEEN subtree.
        return Field("between", ArrowType.BOOL, True)

    elif expr.tag == EXPR_SUBSTRING:
        # `substring(s, start, length)` — STRING, nullable (null in, null
        # out). The alias wrapper supplies the user-facing name.
        return Field("substring", ArrowType.STRING, True)

    elif expr.tag == EXPR_STRING_FN:
        # ⚠ THE OUTPUT TYPE IS PER-OP, NOT
        # PER-TAG — the one way this family differs from EXPR_MATH_FN below.
        # `string_fn_returns_int` is the single place that answers it, so a
        # new STRFN_* member cannot inherit the wrong type by omission.
        if string_fn_returns_int(expr.string_fn_op()):
            return Field("string_fn", ArrowType.INT64, True)
        return Field("string_fn", ArrowType.STRING, True)

    elif expr.tag == EXPR_STRING_FN_N:
        # PER-OP, like `EXPR_STRING_FN` directly
        # above: `strpos` is INT64 and every other member is Utf8.
        #
        # ⚠ NULLABLE IS `True` FOR EVERY MEMBER INCLUDING `concat`, WHICH CAN
        # NEVER PRODUCE A NULL. Declaring `False` would be tighter and is a
        # trap: `test_projection_type_matches_data` compares `arrow_type` and
        # NOT `nullable`, so a `False` here that the kernel contradicts is
        # uninstrumented — the shape that made `EXPR_STRING_OP`'s
        # `Field(..., BOOL, False)` a schema disagreeing with its own column.
        # A nullable field over a column with no nulls is always sound.
        #
        # ⭐ THREE-WAY, NOT TWO. The
        # string-similarity family (`jaro_similarity`, `jaro_winkler_
        # similarity`, `jaccard`) produces FLOAT64; with only a TWO-WAY
        # choice a similarity in [0,1] could not be typed by the family that
        # carries every other two-string kernel.
        #
        # ⛔ THE ORDER OF THESE TWO TESTS IS NOT A STYLE CHOICE. An op named by
        # BOTH predicates would resolve by arm order — silently, and to a
        # different type in each consumer that spells the arms in a different
        # order. `string_fn_n_type_is_coherent` in `expr.mojo` states that no
        # such op exists; it is a declared invariant with a test over the whole
        # range, not an assumption this arm makes.
        if string_fn_n_returns_int(expr.string_fn_n_op()):
            return Field("string_fn_n", ArrowType.INT64, True)
        if string_fn_n_returns_float(expr.string_fn_n_op()):
            return Field("string_fn_n", ArrowType.FLOAT64, True)
        return Field("string_fn_n", ArrowType.STRING, True)

    elif expr.tag == EXPR_MATH_FN or expr.tag == EXPR_MATH_FN2:
        # Every scalar math fn is FLOAT64 whatever its op — the one family
        # whose type is per-TAG rather than per-op.
        return Field("math_fn", ArrowType.FLOAT64, True)

    elif expr.tag == EXPR_UDF_CALL:
        # ★ THE TYPE IS READ OFF THE NODE, NOT
        # INFERRED — a UDF has no operator rule to derive one from; its
        # output type is whatever the customer's function RETURNS, carried
        # here by `out_type`, whose single writer is `ScalarUdf.__call__`
        # reading a comptime member of the signature. Nullable either way:
        # the UDF kernels propagate the argument's validity.
        return Field("udf", expr.udf_call_out_type(), True)

    elif expr.tag == EXPR_JSON_EXTRACT:
        # ★ `_eval_column_expr` HAS an EXPR_JSON_EXTRACT arm, so without this
        # one `SELECT j -> '$.a'` computes CORRECT DATA and then declares it
        # `null`, and the Arrow C-ABI export refuses the whole result. The
        # gate compares the TYPE ladder to the DATA ladder to catch this.
        #
        # ★ THE TYPE IS READ OFF THE NODE, like EXPR_UDF_CALL: `->` vs `->>`
        # and the target type are a property of the parsed operator, carried
        # as `output_type`, and the SAME accessor is what the eval arm passes
        # to `json_extract_column`. One reader, one writer — no rule is
        # restated here.
        return Field("json_extract", expr.json_extract_output_type(), True)

    elif expr.tag == EXPR_EXTRACT:
        # ★ The eval arm computes `extract(year from d)` and `date_trunc(...)`;
        # without this arm both would be typed `null`.
        #
        # ⚠ THE RULE IS NOT RESTATED HERE, IT IS DELEGATED. `_is_trunc_unit`
        # in `expr.mojo` is the SINGLE discriminator between the two
        # families, and it is the same one `_eval_column_expr` branches on —
        # copying the unit list into this file would be the very defect this
        # module exists to delete.
        #
        #   trunc units  -> the CHILD's own temporal type. The eval arm
        #                   explicitly re-stamps `col_out.arrow_type` to
        #                   DATE32 / the source TIMESTAMP unit, so the
        #                   declared type must follow the child, not the
        #                   Int32/Int64 storage the kernel returned.
        #   field units  -> INT64 (year / month / day / quarter / hour /
        #                   minute / second).
        #
        # ⭐ TWO RULES IN THIS ARM, BOTH INVISIBLE TO A VALUE COMPARISON:
        #
        # (1) THE FIELD FAMILY IS INT64, NOT INT32. `_eval_column_expr`
        #     emits INT64 (matching DuckDB v1.5.3's BIGINT and this engine's
        #     ROW executor). Declaring INT32 over an INT64 buffer would make
        #     the two ladders disagree about the SAME executor's output.
        #
        # (2) THE TRUNC ARM KEEPS `_tz`. `Field(name, arrow_type, True)` is
        #     the bare 3-arg ctor and it zeroes every other slot, so
        #     `date_trunc('month', ts_utc)` would DECLARE a tz-less timestamp
        #     over a column whose tz the eval arm preserves — the same mistake
        #     the EXPR_ALIAS arm above avoids. The child field is carried and
        #     RENAMED instead, exactly as the alias arm does, which also
        #     carries decimal (p,s), `_dict_index_type`, `_flags`, kv-metadata
        #     and nested children for free.
        if _is_trunc_unit(expr.extract_unit()):
            var trunc_child = walk_expr_field[P](
                expr.extract_child_ref(), schema, missing
            )
            trunc_child.name = String("date_trunc")
            return trunc_child^
        return Field("extract", ArrowType.INT64, True)

    elif expr.tag == EXPR_STRUCT_FIELD:
        var sf_parent = walk_expr_field[P](
            expr.struct_field_parent_ref(), schema, missing
        )
        if sf_parent.arrow_type != ArrowType.STRUCT:
            return Field("struct_field", ArrowType.NULL, True)
        var sf_name = expr.struct_field_name()
        for i in range(sf_parent.num_children()):
            if sf_parent.child_name(i) == sf_name:
                return Field(
                    sf_name,
                    sf_parent.child_arrow_type(i),
                    sf_parent.child_nullable(i),
                )
        return Field(sf_name, ArrowType.NULL, True)

    elif expr.tag == EXPR_STRUCT_FIELD_IDX:
        var si_parent = walk_expr_field[P](
            expr.struct_field_idx_parent_ref(), schema, missing
        )
        if si_parent.arrow_type != ArrowType.STRUCT:
            return Field("struct_field", ArrowType.NULL, True)
        var si_idx = expr.struct_field_index()
        if si_idx < 0 or si_idx >= si_parent.num_children():
            return Field("struct_field", ArrowType.NULL, True)
        return Field(
            si_parent.child_name(si_idx),
            si_parent.child_arrow_type(si_idx),
            si_parent.child_nullable(si_idx),
        )

    elif expr.tag == EXPR_MAP_GET:
        # Schema-level MAP convention: a MAP Field declares TWO FLAT children
        # — child[0] key, child[1] value — matching how STRUCT Fields declare
        # theirs. The runtime Column layout follows the Arrow spec strictly
        # (one entries STRUCT with key/value sub-children); the flat-children
        # convention keeps this walk uniform with STRUCT.
        var mg_parent = walk_expr_field[P](expr.map_get_parent_ref(), schema, missing)
        if mg_parent.arrow_type != ArrowType.MAP:
            return Field("map_get", ArrowType.NULL, True)
        if mg_parent.num_children() < 2:
            return Field("map_get", ArrowType.NULL, True)
        return Field(
            mg_parent.child_name(1),
            mg_parent.child_arrow_type(1),
            mg_parent.child_nullable(1),
        )

    else:
        # ⛔ REACHING HERE PRODUCES AN UNEXPORTABLE COLUMN. The tags still
        # landing here are enumerated in the derived-facts block above and
        # pinned by a repository lint.
        return Field("expr", ArrowType.NULL, True)
