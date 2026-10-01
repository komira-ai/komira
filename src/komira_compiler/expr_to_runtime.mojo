# =============================================================================
# komira_compiler.expr_to_runtime — LogicalPlan Expr -> RuntimeExpr translator
#
# Translates a `komira_core.plan.expr.Expr` (the LogicalPlan-side tagged
# tree carrying the full predicate-vocabulary the planner emits) into the
# `komira_eval.expr_ast.RuntimeExpr` AoS-as-index-arena that the row-mode
# `ExpressionExecutor` walker consumes.
#
# Why this translator
# -------------------
# The row-mode walker `ExpressionExecutor.select_expression_adaptive` is
# the new fast-path for filter predicates over the Q6 / Q14 / Q1-shape
# subset (numeric AND-chains over Col / Lit). Predicates outside this
# subset (strings, NOT, IS_NULL, BETWEEN, IN_LIST, scalar BinaryOp,
# EXPR_AGG_FN scalar-broadcast, EXPR_WHEN, etc.) still flow through the
# legacy `evaluate_filter_narrowed` path in `OpFilter` per the M4
# dual-path design. The translator returns `Optional[(pool, root_idx)]`:
#
#   - Some((pool, root_idx)) — predicate is fully translatable; caller
#     builds `ExpressionExecutor` over the pool and invokes
#     `OpFilter.with_adaptive_executor` to activate the row-mode path.
#   - None — at least one node in the predicate tree is unsupported;
#     caller falls back to the legacy `OpFilter(predicate)` ctor.
#
# Supported subset (M6)
# ---------------------
# LEAVES:
#   - EXPR_COL_REF      -> EXPR_COL with `col_idx` resolved against the
#                          child output_schema by name.
#   - EXPR_LITERAL      -> EXPR_LIT_I64 / EXPR_LIT_F64 / EXPR_LIT_BOOL
#                          based on the ScalarValue.dtype. Int32 literals
#                          widen to EXPR_LIT_I64 (the walker accepts the
#                          wider type and narrows at sel_kernel dispatch
#                          per the M3 walker convention). Date32 literals
#                          translate to EXPR_LIT_I64 carrying the
#                          days-since-epoch value (matches the
#                          q6_untyped MVP shipdate path).
#
# BINARY OPS (numeric only, Col-on-LEFT / Lit-on-RIGHT canonicalization):
#   - BIN_GT, BIN_GE, BIN_LT, BIN_LE, BIN_EQ over Int64 and Float64.
#     The walker's _dispatch_comparison expects Col on the LEFT — if the
#     planner emits Lit-on-LEFT we mirror the comparison (e.g.
#     `5 < x` -> `x > 5`). This canonicalization is a translator-side
#     concern; the runtime walker stays simple.
#   - BIN_AND — recursive flattening into RuntimeExpr.EXPR_AND nodes.
#     BIN_OR is NOT supported (the walker raises on EXPR_OR in M3/M5).
#
# DType resolution
# ----------------
# The translator needs the child output_schema to resolve EXPR_COL_REF
# names into column indices AND to pick the comparison's DType (Int64 vs
# Float64 vs Date32). The schema is consulted only at column references;
# literal DTypes come from `ScalarValue.dtype`. We require LEFT operand
# DType == RIGHT operand DType (no implicit widening) — predicates with
# a mismatched-DType comparison return None.
#
# Cross-references:
#   - `src/komira_core/plan/expr.mojo` — input Expr tree (tag + variant data).
#   - `src/komira_eval/expr_ast.mojo` — output RuntimeExpr pool.
#   - `src/komira_eval/expression_executor.mojo` — consumer; see the
#     M3/M5 walker contract for what the pool must look like.
#   - `src/komira_engine_operators/op_filter.mojo` — `with_adaptive_executor`
#     factory wires the executor into OpFilter.
# =============================================================================

from std.memory import OwnedPointer

from komira_core.plan.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    BIN_EQ,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
)
from komira_core.plan.scalar_value import (
    ScalarValue,
    SCALAR_KIND_DTYPE,
    SCALAR_KIND_DATE32,
)
from komira_core.arrow.schema import Schema

from komira_eval.runtime_expr import (
    RuntimeExpr,
    EXPR_AND,
    EXPR_COL,
    EXPR_EQ_F64,
    EXPR_EQ_I64,
    EXPR_GE_F64,
    EXPR_GE_I64,
    EXPR_GT_F64,
    EXPR_GT_I64,
    EXPR_LE_F64,
    EXPR_LE_I64,
    EXPR_LIT_F64,
    EXPR_LIT_I64,
    EXPR_LT_F64,
    EXPR_LT_I64,
    make_and,
    make_col,
    make_eq_f64,
    make_ge_f64,
    make_ge_i64,
    make_le_f64,
    make_le_i64,
    make_lit_f64,
    make_lit_i64,
    make_lt_f64,
    make_lt_i64,
)


# -----------------------------------------------------------------------------
# Result struct — the translator returns an Optional[TranslatedExpr].
# -----------------------------------------------------------------------------
#
# We carry the pool + root_idx + n_conjuncts (the count of leaf-conjuncts
# under a top-level AND chain) so the caller can size the AdaptiveFilter
# correctly when invoking `FilterState.with_conjunction(n_predicates, wid)`.


@fieldwise_init
struct TranslatedExpr(Movable):
    """Result of a successful Expr -> RuntimeExpr translation.

    Fields:
        pool: The RuntimeExpr AoS-as-index-arena. Root is at
              `pool[root_idx]`. Children are referenced by `left`/`right`
              slot indices into this pool.
        root_idx: Slot index of the root node.
        n_conjuncts: Number of leaf-conjuncts under the root's AND chain
              (>= 1 — `1` when the root is not an AND). Sized for the
              `FilterState.with_conjunction(n_predicates, wid)` factory.
        column_names: Sidecar parallel list of column NAMES referenced
              by EXPR_COL nodes in `pool`. Indexed by `RuntimeExpr.col_idx`
              (which becomes a slot index into this list, NOT a position
              into any schema). The walker resolves each name to the
              runtime batch position via `batch.column_by_name(name)` at
              evaluation time. This sidecar shape (vs an inline
              `String` field on `RuntimeExpr`) preserves the POD
              invariant for `List[RuntimeExpr]` storage — only EXPR_COL
              nodes index into `column_names`; literal / op nodes do not.
              Identical structural shape to ExpressionExecutor's
              `expression_pool: List[RuntimeExpr]` + `intermediate_buf`
              List[UInt8] fields.
    """

    var pool: List[RuntimeExpr]
    var root_idx: Int
    var n_conjuncts: Int
    var column_names: List[String]


# -----------------------------------------------------------------------------
# Public entry point.
# -----------------------------------------------------------------------------


def translate_filter_predicate(
    predicate: Expr, child_schema: Schema
) raises -> Optional[TranslatedExpr]:
    """Translate a filter predicate into a RuntimeExpr pool.

    Walks the LogicalPlan Expr tree recursively. On any unsupported
    shape, returns `None` (caller falls back to the legacy
    `OpFilter(predicate)` path). On success, returns a `TranslatedExpr`
    holding the pool + root index + leaf-conjunct count.

    Args:
        predicate: The LogicalPlan filter predicate.
        child_schema: The output schema of the filter's child plan node;
                      used to resolve `EXPR_COL_REF` names into column
                      indices and to pick comparison DTypes.

    Returns:
        Some(TranslatedExpr(pool, root_idx, n_conjuncts)) on success.
        None on any unsupported shape.

    Raises:
        Error only on internal invariant violations (never raised in
        practice for the supported subset — exists to match the
        ScalarValue.copy-raises chain).
    """
    # Structural-feasibility
    # fast pre-check. Walks the predicate tree once, bailing on the
    # FIRST node with an unsupported tag (sub-100ns common reject case).
    # This preserves `test_metadata_fast_path_is_fast`'s 1ms budget by
    # short-circuiting unsupported predicates BEFORE the full translator
    # walk allocates the pool / name list. The full translator's
    # per-node tag-check would also reject these, but the pre-check is
    # O(node count) with an early-exit (vs O(node count) with full
    # alloc on each visit).
    if not _is_translatable_shape(predicate):
        return Optional[TranslatedExpr](None)

    var pool = List[RuntimeExpr]()
    var column_names = List[String]()
    var root_idx = _translate_node(predicate, child_schema, pool, column_names)
    if root_idx < 0:
        return Optional[TranslatedExpr](None)
    var n_conjuncts = _count_conjuncts(pool, root_idx)
    return Optional[TranslatedExpr](
        TranslatedExpr(pool^, root_idx, n_conjuncts, column_names^)
    )


# -----------------------------------------------------------------------------
# Internal — translate a single Expr node, return its pool slot index.
# Returns -1 on unsupported shape (signals failure to the caller's
# Optional[TranslatedExpr] return path).
# -----------------------------------------------------------------------------


def _translate_node(
    expr: Expr,
    child_schema: Schema,
    mut pool: List[RuntimeExpr],
    mut column_names: List[String],
) raises -> Int:
    """Translate one Expr node + descendants into `pool`. Return slot or -1."""
    if expr.tag == EXPR_BINARY_OP:
        return _translate_binary(expr, child_schema, pool, column_names)
    if expr.tag == EXPR_COL_REF:
        return _translate_col_ref(expr, child_schema, pool, column_names)
    if expr.tag == EXPR_LITERAL:
        return _translate_literal(expr, pool)
    # All other tags (EXPR_COL_IDX, EXPR_UNARY_OP, EXPR_CAST, EXPR_ALIAS,
    # EXPR_STRING_OP, EXPR_WHEN, EXPR_AGG_FN, EXPR_WINDOW_FN, EXPR_IN_LIST,
    # EXPR_CORRELATED_SUBQUERY, EXPR_REGEXP, EXPR_STRUCT_FIELD,
    # EXPR_STRUCT_FIELD_IDX, EXPR_MAP_GET) are out of scope for the
    # row-mode walker today. Fall back to the legacy path.
    return -1


# -----------------------------------------------------------------------------
# Binary-op translation: AND + comparisons.
# -----------------------------------------------------------------------------


def _translate_binary(
    expr: Expr,
    child_schema: Schema,
    mut pool: List[RuntimeExpr],
    mut column_names: List[String],
) raises -> Int:
    """Translate an EXPR_BINARY_OP. Returns pool slot or -1.

    Supported op codes:
      - BIN_AND     -> EXPR_AND (recursive descent)
      - BIN_GT/GE/LT/LE/EQ -> EXPR_*_I64 or EXPR_*_F64 based on operand
                              DType. Canonicalizes Lit-on-LEFT to
                              Col-on-LEFT by mirroring the comparison.
    """
    ref b = expr._binary.value()
    var op = b.op

    # ---- AND: recursive descent ------------------------------------------
    if op == BIN_AND:
        var left_idx = _translate_node(b.left[], child_schema, pool, column_names)
        if left_idx < 0:
            return -1
        var right_idx = _translate_node(b.right[], child_schema, pool, column_names)
        if right_idx < 0:
            return -1
        pool.append(make_and(left_idx, right_idx))
        return len(pool) - 1

    # ---- Comparisons -----------------------------------------------------
    # Identify Col / Lit operands. Acceptable shapes:
    #   Col <op> Lit  -> canonical (walker convention)
    #   Lit <op> Col  -> mirror (walker still requires Col-on-LEFT)
    #   Col <op> Col  -> kept as-is; walker's _dispatch_comparison
    #                    handles Col-vs-Col through binary_select_col_col.
    #   Lit <op> Lit  -> unsupported (constant-folding should have
    #                    eliminated; if it survived, fall back to legacy).
    if (op != BIN_GT and op != BIN_GE and op != BIN_LT
        and op != BIN_LE and op != BIN_EQ):
        # Other binary ops (BIN_OR, BIN_NE, BIN_ADD, BIN_MUL, ...) are
        # unsupported by the row-mode walker. BIN_OR is explicitly
        # deferred per M3 slot brief; arithmetic-producing ops require
        # walker support for non-boolean results.
        return -1

    ref left = b.left[]
    ref right = b.right[]

    var left_is_col = (left.tag == EXPR_COL_REF)
    var right_is_col = (right.tag == EXPR_COL_REF)
    var left_is_lit = (left.tag == EXPR_LITERAL)
    var right_is_lit = (right.tag == EXPR_LITERAL)

    # Compute the DType for the kernel arm. Both sides must agree.
    var left_dtype = _dtype_of(left, child_schema)
    var right_dtype = _dtype_of(right, child_schema)
    if left_dtype < 0 or right_dtype < 0:
        # Unsupported operand DType (string, decimal, etc).
        return -1
    if left_dtype != right_dtype:
        # Mixed DTypes (the planner may emit cross-type compares; the
        # row-mode walker does NOT implicit-cast at evaluation time).
        # Fall back to the legacy path which handles widening through
        # the eval-predicate scalar machinery.
        return -1
    var dtype = left_dtype  # 0=Int64, 1=Float64

    # Canonicalize Lit-on-LEFT to Col-on-LEFT by mirroring the op.
    var canon_op = op
    var canon_left_is_col = left_is_col
    var canon_left_is_lit = left_is_lit
    var canon_right_is_col = right_is_col
    var canon_right_is_lit = right_is_lit
    var canon_left_idx_in_pool: Int
    var canon_right_idx_in_pool: Int

    if left_is_lit and right_is_col:
        # Mirror: `5 < x` -> `x > 5` (i.e. swap operands + flip op).
        canon_op = _flip_comparison(op)
        canon_left_is_col = True
        canon_left_is_lit = False
        canon_right_is_col = False
        canon_right_is_lit = True
        var col_idx = _translate_col_ref(right, child_schema, pool, column_names)
        if col_idx < 0:
            return -1
        var lit_idx = _translate_literal(left, pool)
        if lit_idx < 0:
            return -1
        canon_left_idx_in_pool = col_idx
        canon_right_idx_in_pool = lit_idx
    elif left_is_col and right_is_lit:
        var col_idx = _translate_col_ref(left, child_schema, pool, column_names)
        if col_idx < 0:
            return -1
        var lit_idx = _translate_literal(right, pool)
        if lit_idx < 0:
            return -1
        canon_left_idx_in_pool = col_idx
        canon_right_idx_in_pool = lit_idx
    elif left_is_col and right_is_col:
        var l_idx = _translate_col_ref(left, child_schema, pool, column_names)
        if l_idx < 0:
            return -1
        var r_idx = _translate_col_ref(right, child_schema, pool, column_names)
        if r_idx < 0:
            return -1
        canon_left_idx_in_pool = l_idx
        canon_right_idx_in_pool = r_idx
    else:
        # Lit/Lit, or operand is itself a complex sub-expression (e.g.
        # `x + 1 < 5` where left is a BinaryOp). The row-mode walker
        # only handles Col/Lit leaves; fall back to legacy.
        return -1

    # Emit the RuntimeExpr comparison node based on (canon_op, dtype).
    if dtype == 0:  # Int64
        if canon_op == BIN_GT:
            pool.append(_make_gt_i64_node(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        elif canon_op == BIN_GE:
            pool.append(make_ge_i64(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        elif canon_op == BIN_LT:
            pool.append(make_lt_i64(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        elif canon_op == BIN_LE:
            # Int64 BIN_LE produces EXPR_LE_I64 (sibling of make_lt_i64).
            pool.append(make_le_i64(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        elif canon_op == BIN_EQ:
            pool.append(_make_eq_i64_node(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        else:
            return -1
        return len(pool) - 1
    else:  # Float64 (dtype == 1)
        if canon_op == BIN_GT:
            pool.append(_make_gt_f64_node(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        elif canon_op == BIN_GE:
            pool.append(make_ge_f64(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        elif canon_op == BIN_LT:
            pool.append(make_lt_f64(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        elif canon_op == BIN_LE:
            pool.append(make_le_f64(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        elif canon_op == BIN_EQ:
            # Float64 BIN_EQ produces EXPR_EQ_F64 (sibling of make_le_f64
            # / _make_eq_i64_node).
            pool.append(make_eq_f64(
                canon_left_idx_in_pool, canon_right_idx_in_pool
            ))
        else:
            return -1
        return len(pool) - 1


# -----------------------------------------------------------------------------
# Local factory helpers — the public expr_ast.mojo factories don't ship
# EXPR_EQ_I64 / EXPR_GT_F64 directly; we synthesize the RuntimeExpr nodes
# here using the same 7-arg ctor the public factories use. Once the public
# factory set expands, these can be replaced with `make_eq_i64` /
# `make_gt_f64` imports.
# -----------------------------------------------------------------------------


@always_inline
def _make_gt_i64_node(left: Int, right: Int) -> RuntimeExpr:
    """EXPR_GT_I64 node — mirrors `make_gt_i64` from expr_ast.mojo."""
    return RuntimeExpr(EXPR_GT_I64, 0, 0.0, False, 0, left, right)


@always_inline
def _make_eq_i64_node(left: Int, right: Int) -> RuntimeExpr:
    """EXPR_EQ_I64 node — no public factory in expr_ast.mojo yet.

    Matches the 7-arg RuntimeExpr ctor convention used by the existing
    factories: kind, i64, f64, b, col_idx, left, right.
    """
    return RuntimeExpr(EXPR_EQ_I64, 0, 0.0, False, 0, left, right)


@always_inline
def _make_gt_f64_node(left: Int, right: Int) -> RuntimeExpr:
    """EXPR_GT_F64 node — no public factory in expr_ast.mojo yet."""
    return RuntimeExpr(EXPR_GT_F64, 0, 0.0, False, 0, left, right)


# -----------------------------------------------------------------------------
# Col-ref translation: resolve name -> column index via child_schema.
# -----------------------------------------------------------------------------


def _translate_col_ref(
    expr: Expr,
    child_schema: Schema,
    mut pool: List[RuntimeExpr],
    mut column_names: List[String],
) raises -> Int:
    """Resolve `expr._col_ref.value.name` -> sidecar slot -> EXPR_COL node.

    col_idx is a SLOT INDEX
    into the parallel `column_names` sidecar list, NOT a position in
    the LogicalPlan child schema. The walker resolves the name to a
    runtime batch column position via `batch.column_by_name(name)` at
    evaluation time — this is robust to projection-pushdown column
    reordering (the bug that caused the M6.3 deferral).

    DType validation against `child_schema` still happens via the
    caller's `_dtype_of` invocation — we keep the schema parameter to
    surface "column not in any schema seen by translator" early as an
    Optional[None] (defensive: if the planner emits a predicate over
    a column that's not in the apparent child schema, we don't fail
    silently at runtime — we reject at translate time).

    Returns the pool slot for the new EXPR_COL node, or -1 if the name
    is not found in the schema.
    """
    var name = expr._col_ref.value().name
    var n = child_schema.num_columns()
    var i = 0
    while i < n:
        if child_schema.field_name(i) == name:
            # Allocate a fresh slot in the column_names sidecar; the
            # RuntimeExpr's col_idx becomes the slot index.
            var slot_idx = len(column_names)
            column_names.append(name.copy())
            pool.append(make_col(slot_idx))
            return len(pool) - 1
        i += 1
    # Column not in schema — translator failure; the planner should have
    # validated this earlier, but we surface the failure as Optional[None]
    # to be defensive.
    return -1


# -----------------------------------------------------------------------------
# Literal translation: map ScalarValue.dtype to EXPR_LIT_*.
# -----------------------------------------------------------------------------


def _translate_literal(
    expr: Expr, mut pool: List[RuntimeExpr]
) raises -> Int:
    """Translate an EXPR_LITERAL into an EXPR_LIT_I64 / EXPR_LIT_F64 node.

    Date32 literals translate to EXPR_LIT_I64 carrying the days-since-
    epoch value (matches the row-mode walker's Date32 = Int64-storage
    convention from the q6_untyped MVP).

    Returns the pool slot or -1 if the literal's DType is unsupported.
    """
    ref lit = expr._literal.value()
    ref sv = lit.value
    if sv._kind == SCALAR_KIND_DATE32:
        # Date32 -> Int64-storage days-since-epoch literal. The row-mode
        # walker compares against an Int64 column (parquet l_shipdate is
        # Int64; see q6_untyped bench schema verification).
        pool.append(make_lit_i64(Int64(Int(sv.date32_val))))
        return len(pool) - 1
    if sv._kind != SCALAR_KIND_DTYPE:
        # Decimal128 / Timestamp etc — unsupported for the row-mode
        # walker.
        return -1
    # carry every Int64-family integer literal
    # (int8/16/32/64 + uint8/16/32) as an I64 lit — value lives in int_val.
    if sv.fits_int64_family():
        pool.append(make_lit_i64(sv.int_val))
        return len(pool) - 1
    if sv.dtype == DType.float64 or sv.dtype == DType.float32:
        pool.append(make_lit_f64(sv.float_val))
        return len(pool) - 1
    # Bool/string/null literals at the leaf of a comparison aren't
    # expected; fall back.
    return -1


# -----------------------------------------------------------------------------
# DType-of helper. Returns:
#   0 -> Int64-family (Int64 column, Int64 literal, Int32 literal, Date32 literal)
#   1 -> Float64-family (Float64 column, Float64 literal, Float32 literal)
#  -1 -> unsupported (string / decimal / bool / etc)
# -----------------------------------------------------------------------------


def _dtype_of(expr: Expr, child_schema: Schema) -> Int:
    """Return 0 (Int family), 1 (Float family), or -1 (unsupported)."""
    if expr.tag == EXPR_COL_REF:
        var name = expr._col_ref.value().name
        var n = child_schema.num_columns()
        var i = 0
        while i < n:
            if child_schema.field_name(i) == name:
                var dt = child_schema.field_dtype(i)
                if dt == DType.int64 or dt == DType.int32:
                    return 0
                if dt == DType.float64 or dt == DType.float32:
                    return 1
                return -1
            i += 1
        return -1
    if expr.tag == EXPR_LITERAL:
        ref lit = expr._literal.value()
        ref sv = lit.value
        if sv._kind == SCALAR_KIND_DATE32:
            return 0  # Date32 stores as Int64-family
        if sv._kind != SCALAR_KIND_DTYPE:
            return -1
        # all Int64-family integers (int8/16/32/64 + uint8/16/32)
        # classify as the Int family.
        if sv.fits_int64_family():
            return 0
        if sv.dtype == DType.float64 or sv.dtype == DType.float32:
            return 1
        return -1
    # Other tags aren't translatable as comparison operands; the caller
    # returns -1 to the outer translator which yields None.
    return -1


# -----------------------------------------------------------------------------
# Mirror a comparison: swap operands -> flip the op.
#   GT <-> LT,  GE <-> LE,  EQ -> EQ.
# Returns 255 (sentinel) if the op is not in the supported family.
# -----------------------------------------------------------------------------


@always_inline
def _flip_comparison(op: UInt8) -> UInt8:
    """Return the comparison op that swaps left/right operands.

    `a > b` <-> `b < a`, `a >= b` <-> `b <= a`, `a == b` <-> `b == a`.
    """
    if op == BIN_GT:
        return BIN_LT
    if op == BIN_LT:
        return BIN_GT
    if op == BIN_GE:
        return BIN_LE
    if op == BIN_LE:
        return BIN_GE
    if op == BIN_EQ:
        return BIN_EQ
    return UInt8(255)


# -----------------------------------------------------------------------------
# Count leaf-conjuncts under the root's AND chain (for sizing
# `FilterState.with_conjunction(n_predicates, wid)`).
# -----------------------------------------------------------------------------


def _count_conjuncts(pool: List[RuntimeExpr], root_idx: Int) -> Int:
    """Recursively count the leaf-conjuncts under the root AND chain.

    For a non-AND root, returns 1. For an AND chain like
    `AND(AND(p0, p1), AND(p2, p3))` returns 4.
    """
    var node = pool[root_idx]
    if node.kind != EXPR_AND:
        return 1
    return _count_conjuncts(pool, node.left) + _count_conjuncts(
        pool, node.right
    )


# -----------------------------------------------------------------------------
# Structural-feasibility fast pre-check.
# -----------------------------------------------------------------------------
#
# Walks the predicate tree once, returning False on the FIRST node with
# an unsupported tag. Cheaper than the full `_translate_node` walk for
# the common "no chance" case (strings, IN_LIST, NOT, ALIAS, AGG_FN,
# WHEN, BinaryOp with arithmetic op, BIN_OR, ...). Sub-100ns reject for
# any predicate whose root or top-level operand is unsupported.
#
# Why: `test_metadata_fast_path_is_fast`
# has a 1ms FAST_PATH_BUDGET_NS — the full translator's per-node tag-
# check + List allocations could blow that budget on every plan-compile.
# Pre-check returns early without allocating, preserving fast-path
# budgets when the planner emits a wide variety of filters during
# metadata pruning + row-group hoist.
#
# The pre-check NEVER produces a different answer than the full
# translator for shapes it rejects — the full translator would also
# return -1. Pre-check is a strict optimization, not a behavior change.


def _is_translatable_shape(predicate: Expr) -> Bool:
    """Return True if the predicate's tree has only translator-supported
    tag shapes. O(node count) with bailout on first bad tag.

    Supported tags (mirrors `_translate_node` / `_translate_binary`):
      - EXPR_COL_REF
      - EXPR_LITERAL
      - EXPR_BINARY_OP with op in {BIN_AND, BIN_GT, BIN_GE, BIN_LT,
        BIN_LE, BIN_EQ}
    Any other tag (EXPR_UNARY_OP, EXPR_CAST, EXPR_ALIAS, EXPR_STRING_OP,
    EXPR_WHEN, EXPR_AGG_FN, EXPR_WINDOW_FN, EXPR_IN_LIST, EXPR_REGEXP,
    ...) returns False.

    NOTE: This is a shape check only — operand-side DType / column-
    name resolution still happens in the full translator and may
    return -1 on details the pre-check can't see (mixed DTypes,
    unknown column names, complex sub-expressions on a comparison
    side, etc.). Pre-check ensures we don't pay alloc cost on
    obviously-unsupported shapes.

    Args:
        predicate: The LogicalPlan filter predicate.

    Returns:
        True if every node's tag is in the translator-supported subset.
        False on any unsupported tag (early return).
    """
    if predicate.tag == EXPR_COL_REF:
        return True
    if predicate.tag == EXPR_LITERAL:
        return True
    if predicate.tag == EXPR_BINARY_OP:
        if not predicate._binary:
            return False
        ref b = predicate._binary.value()
        var op = b.op
        # Only AND + the 5 supported comparison ops survive.
        if (op != BIN_AND and op != BIN_GT and op != BIN_GE
            and op != BIN_LT and op != BIN_LE and op != BIN_EQ):
            return False
        # Recurse into both sides; bail on first failure.
        if not _is_translatable_shape(b.left[]):
            return False
        if not _is_translatable_shape(b.right[]):
            return False
        return True
    # All other tags (EXPR_UNARY_OP, EXPR_CAST, EXPR_ALIAS,
    # EXPR_STRING_OP, EXPR_WHEN, EXPR_AGG_FN, EXPR_WINDOW_FN,
    # EXPR_IN_LIST, EXPR_REGEXP, EXPR_STRUCT_FIELD, ...) are
    # unsupported.
    return False
