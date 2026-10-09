# =============================================================================
# RuntimeExprBool — runtime tree wrapper conforming to ExprBoolU
# =============================================================================
#
# This is the load-bearing runtime-tree-wrapper that conforms to the
# unified `ExprBoolU` trait. The engine filter kernel
# (`filter_apply[E: ExprBoolU]`) monomorphizes uniformly over either world:
#   - Comptime-typed AST conformer (zero-field struct, planner-emitted), OR
#   - This runtime-tree wrapper (planner-built when the predicate
#     comes from SDK helpers like `col("a") > lit(100)`).
#
# The trait-wrapper architecture runs at 1.0x of a hand-written loop under
# shape-classify-then-tight-loop dispatch. The tag set matches the planner's
# runtime Expr tag space (LIT_BOOL/INT/FLOAT/STR, COL_REF, COMPARISON,
# AND/OR/NOT, IS_NULL, BETWEEN, IN_LIST, BIN_OP, EXPR_AGG_FN, EXPR_WHEN,
# EXPR_CAST).
#
# Contents:
#   - Tag enum + RuntimeNode POD struct
#   - RuntimeExprBool struct with InlineArray[RuntimeNode, MAX_NODES]
#     storage (List is not Copyable, so it can't be a field on a
#     Copyable-conforming struct).
#   - Tree walker `eval[W]` dispatching on tag; AND/OR/NOT arms call the
#     Kleene helpers.
#   - `run_filter_self` whole-batch entry point forwarding to the
#     free-function default.
#   - Shape-classify stub returning FALLBACK.
#   - Builder `build_runtime_expr_bool` over a hand-built node list
#     (raises on node-count overflow and on an out-of-range root).
#
# Not yet implemented:
#   - Per-tag arms for LIT_STR / IN_LIST / EXPR_AGG_FN / EXPR_WHEN /
#     EXPR_CAST: the walker raises an Error on them.
#   - A production fast-path shape registry.
#   - A translation from the planner's Expr tree to a node list.
#
# Encapsulation invariants:
#   - No `UnsafePointer` in any public method signature.
#   - All borrows are tracked via `BatchView[origin]` / `ByteView[origin]`
#     with concrete `origin` parameters.
#   - `InlineArray[RuntimeNode, MAX_NODES]` storage is heap-free
#     (no stale-slab hazard — RuntimeNode is a POD with no heap fields).
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_buffer.byte_view import ByteView
from komira_kernels.eval_chunks import EvalBoolChunk, EvalI64Chunk
from komira_expr.expr_traits_unified import (
    ExprBoolU,
    _default_run_filter_self_unified,
)
from komira_kernels.kleene import (
    _kleene_and_chunk,
    _kleene_or_chunk,
    _kleene_not_chunk,
)


# =============================================================================
# Tag enum — 16 tags Theme 1
# =============================================================================
#
# These mirror the planner's runtime Expr tag space (see
# `komira_plan_expr.expr`). The 16-tag set is the
# full tag scope, including EXPR_AGG_FN and EXPR_WHEN.
#
# Tag numbering is INDEPENDENT of the planner's EXPR_* constants —
# the runtime-tree storage shape is a compressed POD form. Nothing in
# this module translates planner tags to runtime tags.
# =============================================================================


comptime RT_LIT_BOOL: UInt8 = 0     # Bool literal
comptime RT_LIT_INT: UInt8 = 1      # Int64 literal
comptime RT_LIT_FLOAT: UInt8 = 2    # Float64 literal
comptime RT_LIT_STR: UInt8 = 3      # String literal (LIT_STR — would need a string-pool reference)
comptime RT_COL_REF: UInt8 = 4      # Column reference by index
comptime RT_COMPARISON: UInt8 = 5   # Comparison binop: lt/le/gt/ge/eq/ne (sub-op in extra)
comptime RT_AND: UInt8 = 6          # Boolean AND
comptime RT_OR: UInt8 = 7           # Boolean OR
comptime RT_NOT: UInt8 = 8          # Boolean NOT
comptime RT_IS_NULL: UInt8 = 9      # IS_NULL / IS_NOT_NULL (variant in extra)
comptime RT_BETWEEN: UInt8 = 10     # x BETWEEN low AND high
comptime RT_IN_LIST: UInt8 = 11     # x IN (...) — would need an extra-storage list reference
comptime RT_BIN_OP: UInt8 = 12      # Arithmetic binop (add/sub/mul/div/mod) — used by sub-trees of comparisons
comptime RT_EXPR_AGG_FN: UInt8 = 13 # Aggregate function reference (FALLBACK)
comptime RT_EXPR_WHEN: UInt8 = 14   # CASE WHEN ... THEN ... ELSE ... END (FALLBACK)
comptime RT_EXPR_CAST: UInt8 = 15   # Type cast (FALLBACK)

# Comparison sub-op constants (when tag == RT_COMPARISON, `extra`
# carries the comparison kind). Mirror BIN_LT / BIN_LE / BIN_GT /
# BIN_GE / BIN_EQ / BIN_NE from `komira_plan_expr.expr`.
comptime CMP_LT: UInt8 = 0
comptime CMP_LE: UInt8 = 1
comptime CMP_GT: UInt8 = 2
comptime CMP_GE: UInt8 = 3
comptime CMP_EQ: UInt8 = 4
comptime CMP_NE: UInt8 = 5

# IS_NULL sub-variant (when tag == RT_IS_NULL).
comptime ISNULL_IS_NULL: UInt8 = 0
comptime ISNULL_IS_NOT_NULL: UInt8 = 1

# Maximum tree size — bounds RuntimeExprBool's storage. The InlineArray (vs List) is mandatory: List[T] cannot be a field
# on a Copyable struct in Mojo 1.0.0b1, and the trait surface
# (ExprBoolU) requires Copyable conformance.
comptime MAX_NODES: Int = 256


# =============================================================================
# RuntimeNode — POD tagged-union for one node in the runtime tree
# =============================================================================
#
# All fields are scalar (no List / no String / no OwnedPointer).
# Children referenced by Int index into the parent RuntimeExprBool's
# `nodes` array. This shape:
#   - Avoids stale-slab (no heap, no wildcard origin).
#   - Allows InlineArray<RuntimeNode, N> on a Copyable struct.
#   - Trivially Copyable / Movable via @fieldwise_init.
#
# Fields (overloaded per tag):
#   tag        — RT_* discriminator.
#   extra      — sub-op or variant (CMP_*, ISNULL_*, ...).
#   col_idx    — column index (for RT_COL_REF; -1 otherwise).
#   lit_int    — Int64 literal (for RT_LIT_INT; also CMP rhs immediate).
#   lit_float  — Float64 literal (for RT_LIT_FLOAT).
#   lit_bool   — Bool literal (for RT_LIT_BOOL).
#   left_idx   — left child index (binops; -1 for leaves).
#   right_idx  — right child index (binops; -1 for leaves).
#   third_idx  — third child index (BETWEEN: high; WHEN: else; -1 otherwise).
#   list_start — start index into auxiliary "list child" array
#                (IN_LIST / WHEN-multi-branch; -1 default).
#   list_count — count of list children (-1 default).
#
# `lit_str` is NOT a direct field — string literals carry an
# Int reference into a side string-pool. It stores
# 0 in `lit_int` as a placeholder, and the FALLBACK path fires.
# =============================================================================


@fieldwise_init
struct RuntimeNode(Copyable, Movable, ImplicitlyCopyable):
    """One node in the flat runtime Expr tree.

    POD — no pointers, no List, no heap. All children referenced by
    Int index into the parent's `nodes` array. Trivially Copyable /
    Movable via @fieldwise_init.

    See module-doc field-overloading semantics per tag.
    """

    var tag: UInt8        # RT_*
    var extra: UInt8      # Sub-op (CMP_* / ISNULL_*) or 0
    var col_idx: Int      # Column index (RT_COL_REF; -1 otherwise)
    var lit_int: Int64    # Int64 literal (RT_LIT_INT)
    var lit_float: Float64  # Float64 literal (RT_LIT_FLOAT)
    var lit_bool: UInt8   # Bool literal (RT_LIT_BOOL): 0/1
    var left_idx: Int     # Left child (binops; -1 for leaves)
    var right_idx: Int    # Right child (binops; -1 for leaves)
    var third_idx: Int    # Third child (BETWEEN.high; WHEN.else; -1 default)
    var list_start: Int   # aux-list start; -1 default
    var list_count: Int   # aux-list count; -1 default


# Helper constructors — used by tests which build small trees manually.


def rt_lit_bool(value: Bool) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_LIT_BOOL,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(1) if value else UInt8(0),
        left_idx=-1, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_lit_int(value: Int64) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_LIT_INT,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=value,
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=-1, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_lit_float(value: Float64) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_LIT_FLOAT,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=value,
        lit_bool=UInt8(0),
        left_idx=-1, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_lit_str() -> RuntimeNode:
    """Placeholder — string literal references go through a
    side string-pool, which is not implemented. The walker hits FALLBACK
    on this tag."""
    return RuntimeNode(
        tag=RT_LIT_STR,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=-1, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_col_ref(col_idx: Int) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_COL_REF,
        extra=UInt8(0),
        col_idx=col_idx,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=-1, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_comparison(sub_op: UInt8, left: Int, right: Int) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_COMPARISON,
        extra=sub_op,
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=left, right_idx=right, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_and(left: Int, right: Int) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_AND,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=left, right_idx=right, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_or(left: Int, right: Int) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_OR,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=left, right_idx=right, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_not(child: Int) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_NOT,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=child, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_is_null(child: Int, variant: UInt8) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_IS_NULL,
        extra=variant,
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=child, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_between(value: Int, low: Int, high: Int) -> RuntimeNode:
    return RuntimeNode(
        tag=RT_BETWEEN,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=value, right_idx=low, third_idx=high,
        list_start=-1, list_count=-1,
    )


def rt_in_list(value: Int) -> RuntimeNode:
    """Placeholder — IN_LIST list-of-rhs storage (an
    auxiliary list-child array) is not implemented. The walker hits FALLBACK
    on this tag."""
    return RuntimeNode(
        tag=RT_IN_LIST,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=value, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_bin_op(sub_op: UInt8, left: Int, right: Int) -> RuntimeNode:
    """Arithmetic binop (BIN_ADD/SUB/MUL/DIV/MOD per
    expr.mojo). Returns an Int64 sub-tree result; the
    walker uses this only as a comparison-operand sub-tree —
    standalone BIN_OP-as-bool-root is FALLBACK."""
    return RuntimeNode(
        tag=RT_BIN_OP,
        extra=sub_op,
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=left, right_idx=right, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_expr_agg_fn() -> RuntimeNode:
    """FALLBACK — aggregate function references in the bool-
    expr tree path are not implemented (the agg trait is AggI64U /
    AggF64U; their result feeds a non-bool branch). Walker hits
    FALLBACK on this tag."""
    return RuntimeNode(
        tag=RT_EXPR_AGG_FN,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=-1, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_expr_when() -> RuntimeNode:
    """FALLBACK — CASE WHEN is a multi-branch expression
    requiring auxiliary list-child storage, which is not implemented. Walker hits
    FALLBACK on this tag."""
    return RuntimeNode(
        tag=RT_EXPR_WHEN,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=-1, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def rt_expr_cast(child: Int) -> RuntimeNode:
    """FALLBACK — type cast emits a typed-sub-tree (handled
    by the typed kernels). Walker hits FALLBACK on this tag."""
    return RuntimeNode(
        tag=RT_EXPR_CAST,
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=child, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


def _rt_sentinel() -> RuntimeNode:
    """Sentinel node — fills unused slots in the InlineArray. tag=255
    is reserved (out-of-range of the 16-tag set)."""
    return RuntimeNode(
        tag=UInt8(255),
        extra=UInt8(0),
        col_idx=-1,
        lit_int=Int64(0),
        lit_float=Float64(0.0),
        lit_bool=UInt8(0),
        left_idx=-1, right_idx=-1, third_idx=-1,
        list_start=-1, list_count=-1,
    )


# =============================================================================
# ShapeClass — stub
# =============================================================================
#
# Theme 1 — the runtime-tree wrapper can carry a
# pre-classified shape tag so the engine kernel jumps directly to a
# specialized tight-loop body. The stub returns FALLBACK for every input;
# a shape registry would supply the
# classification logic with a small registry of canonical shapes.
# =============================================================================


comptime SHAPE_FALLBACK: UInt8 = 0
comptime SHAPE_AND_GT_LT_LIT: UInt8 = 1
# Further ShapeClass codes are added as new constants here.


@fieldwise_init
struct ShapeClass(Copyable, Movable, ImplicitlyCopyable):
    """Classified shape of the runtime tree — for shape-
    dispatch fast paths. Always returns SHAPE_FALLBACK."""

    var code: UInt8


# =============================================================================
# RuntimeExprBool — the wrapper struct
# =============================================================================


# Mojo 1.0.0: NOT ImplicitlyCopyable -- see ExprBoolU. ~20 KB of inline
# nodes; copies are explicit.
struct RuntimeExprBool(Copyable, Movable, ExprBoolU):
    """Runtime-tree wrapper conforming to the unified `ExprBoolU` trait.

    Storage:
        nodes: InlineArray[RuntimeNode, MAX_NODES] — heap-free, no
            stale-pointer hazard. List[T] cannot be a field on a
            Copyable struct under Mojo 1.0.0b1, and the trait surface
            (ExprBoolU) requires Copyable / Movable / ImplicitlyCopyable
            conformance.
        node_count: number of populated nodes (≤ MAX_NODES).
        root: index of the root node.
        shape: pre-classified shape (always SHAPE_FALLBACK).

    Methods:
        __init__ (no-arg): empty tree, root=-1 (
            required to satisfy the trait surface even though never
            called productively).
        __init__ (with nodes + count + root): the canonical builder
            entry.
        eval[W] (ExprBoolU): per-W-chunk SIMD eval via recursive
            tree walker. AND/OR/NOT arms call the Kleene helpers.
        run_filter_self (ExprBoolU): whole-batch entry. Forwards to
            the free-function default impl.
        shape_classify: returns ShapeClass — stub.

    Build entry:
        build_runtime_expr_bool — wraps a hand-built node list. Raises
            on overflow and on an out-of-range root.

    Encapsulation:
        - No UnsafePointer in any public method signature.
        - All borrows tracked via BatchView[origin] / ByteView[origin].
    """

    var nodes: Array[RuntimeNode, MAX_NODES]
    var node_count: Int
    var root: Int
    var shape: ShapeClass

    def __init__(out self):
        """No-arg ctor — empty tree (root=-1, node_count=0).

        Required by the ExprBoolU trait surface (
        Mojo trait conformance requires explicit `__init__`).
        Never called productively; the production path always goes
        through `__init__(nodes, count, root)` or
        `build_runtime_expr_bool`.
        """
        self.nodes = Array[RuntimeNode, MAX_NODES](fill=_rt_sentinel())
        self.node_count = 0
        self.root = -1
        self.shape = ShapeClass(code=SHAPE_FALLBACK)

    def __init__(
        out self,
        var nodes: Array[RuntimeNode, MAX_NODES],
        node_count: Int,
        root: Int,
    ):
        """Canonical ctor — used by `build_runtime_expr_bool` and by tests.

        Args:
            nodes: Pre-populated node array (sentinel-fill the unused
                slots above `node_count`).
            node_count: Number of populated nodes. Not checked here; the
                walker refuses any node index outside
                [0, min(node_count, MAX_NODES)).
            root: Index of the root node. Not checked here; the walker
                refuses it if it is out of range.
        """
        self.nodes = nodes^
        self.node_count = node_count
        self.root = root
        # Stub — no shape classifier yet.
        self.shape = ShapeClass(code=SHAPE_FALLBACK)

    # -------------------------------------------------------------------------
    # Public accessors
    # -------------------------------------------------------------------------

    @always_inline
    def shape_classify(self) -> ShapeClass:
        """Return the pre-classified shape of this tree.

        stub — always returns SHAPE_FALLBACK. A shape classifier would ship
        the registry of canonical shapes (e.g. AND(GT(col, lit),
        LT(col, lit)) → SHAPE_AND_GT_LT_LIT).
        """
        return self.shape

    # -------------------------------------------------------------------------
    # ExprBoolU trait methods
    # -------------------------------------------------------------------------

    def eval[W: Int](
        self,
        batch: BatchView,
        i: Int,
    ) raises -> EvalBoolChunk[W]:
        """Per-W-chunk SIMD eval — recursive tree walker.

        Walks the tree from `self.root` dispatching on each node's
        tag. AND/OR/NOT arms call the Kleene helpers
        (`_kleene_and_chunk` / `_kleene_or_chunk` / `_kleene_not_chunk`)
        to honor Kleene 3VL semantics.

        Fully-implemented tags:
            RT_LIT_BOOL  — constant Bool splat
            RT_COL_REF   — read W lanes from a Bool column
            RT_COMPARISON — pairwise compare on Int64 column reads
            RT_AND / RT_OR / RT_NOT — Kleene 3VL via the Kleene helpers
            RT_IS_NULL   — propagates validity to Bool result
            RT_BETWEEN   — three-arg compare on Int64 column ops

        STUB tags (raise an Error on encounter):
            RT_LIT_STR / RT_IN_LIST / RT_EXPR_AGG_FN / RT_EXPR_WHEN
            / RT_EXPR_CAST / RT_BIN_OP-as-root / RT_LIT_INT-as-root /
            RT_LIT_FLOAT-as-root — these are not supported
            (string-pool / list-child storage / typed dispatch).

        Raises:
            Error if a STUB tag is encountered or the tree shape is
            invalid (out-of-range child index, etc.).
        """
        return self._eval_node[W](self.root, batch, i)

    def run_filter_self[
        mask_origin: Origin[mut=True],
        validity_origin: Origin[mut=True],
    ](
        self,
        batch: BatchView,
        mask_out: ByteView[mask_origin],
        validity_out: Optional[ByteView[validity_origin]],
    ) raises:
        """Whole-batch entry point. Forwards to the free-
        function default impl (`_default_run_filter_self_unified`).

        A shape-dispatch-then-tight-loop override would dispatch
        ONCE per call; here the dispatch happens ONCE per
        call here, the per-row inner SIMD loop is straight-line.
        """
        _default_run_filter_self_unified[
            RuntimeExprBool, mask_origin, validity_origin
        ](self, batch, mask_out, validity_out)

    # -------------------------------------------------------------------------
    # Internal — bounds-checked node read
    # -------------------------------------------------------------------------

    def _node_at(self, node_idx: Int, caller: StaticString) raises -> RuntimeNode:
        """The node at `node_idx`, or an Error naming `caller` and the index.

        The bound is `node_count` capped at MAX_NODES: `node_count` is a
        public field, and the cap keeps a count set past the array from
        admitting an index outside it. Every read of `self.nodes` in the
        walker goes through here.
        """
        var bound = min(self.node_count, MAX_NODES)
        if node_idx < 0 or node_idx >= bound:
            raise Error(
                String(
                    "RuntimeExprBool.",
                    caller,
                    ": node_idx ",
                    node_idx,
                    " out of bounds [0, ",
                    bound,
                    ")",
                )
            )
        return self.nodes[node_idx]

    # -------------------------------------------------------------------------
    # Internal — recursive node walker
    # -------------------------------------------------------------------------

    def _eval_node[W: Int](
        self,
        node_idx: Int,
        batch: BatchView,
        i: Int,
    ) raises -> EvalBoolChunk[W]:
        """Walk one node — dispatched on `nodes[node_idx].tag`.

        Returns a Bool chunk (the bool-expr tree's value type is
        always Bool at every sub-tree node — Int64/Float64 sub-trees
        feed into RT_COMPARISON / RT_BETWEEN parents that produce
        Bool).
        """
        var node = self._node_at(node_idx, "_eval_node")
        var t = node.tag

        # --- RT_LIT_BOOL ---
        if t == RT_LIT_BOOL:
            var v = node.lit_bool == UInt8(1)
            return EvalBoolChunk[W](
                values=SIMD[DType.bool, W](fill=v),
                validity=SIMD[DType.bool, W](fill=True),
            )

        # --- RT_COL_REF (Bool column read) ---
        if t == RT_COL_REF:
            var col = batch.col_bool(node.col_idx)
            return EvalBoolChunk[W](
                values=col.load[W](i),
                validity=col.validity_load[W](i),
            )

        # --- RT_AND / RT_OR / RT_NOT (Kleene 3VL via the Kleene helpers) ---
        if t == RT_AND:
            var l = self._eval_node[W](node.left_idx, batch, i)
            var r = self._eval_node[W](node.right_idx, batch, i)
            return _kleene_and_chunk[W](l, r)

        if t == RT_OR:
            var l = self._eval_node[W](node.left_idx, batch, i)
            var r = self._eval_node[W](node.right_idx, batch, i)
            return _kleene_or_chunk[W](l, r)

        if t == RT_NOT:
            var c = self._eval_node[W](node.left_idx, batch, i)
            return _kleene_not_chunk[W](c)

        # --- RT_COMPARISON (Int64-column-vs-Int64-column or vs literal) ---
        if t == RT_COMPARISON:
            return self._eval_comparison[W](node, batch, i)

        # --- RT_IS_NULL / RT_IS_NOT_NULL ---
        if t == RT_IS_NULL:
            return self._eval_is_null[W](node, batch, i)

        # --- RT_BETWEEN ---
        if t == RT_BETWEEN:
            return self._eval_between[W](node, batch, i)

        # --- Unsupported tags — FALLBACK path ---
        # RT_LIT_INT / RT_LIT_FLOAT / RT_LIT_STR / RT_IN_LIST /
        # RT_BIN_OP / RT_EXPR_AGG_FN / RT_EXPR_WHEN / RT_EXPR_CAST.
        # These either (a) produce non-Bool types when used standalone
        # (LIT_INT, LIT_FLOAT, BIN_OP) and must be consumed by a
        # COMPARISON/BETWEEN parent — walker handles them
        # only through their parent comparison node, NOT as a Bool
        # tree root, or (b) require auxiliary storage (LIT_STR,
        # IN_LIST, EXPR_AGG_FN, EXPR_WHEN, EXPR_CAST) which is
        # not implemented. Both classes raise the FALLBACK Error here.
        raise Error(
            "RuntimeExprBool._eval_node: FALLBACK for tag "
            + String(Int(t))
            + " — not supported by the runtime tree"
        )

    # -------------------------------------------------------------------------
    # Internal — RT_COMPARISON evaluator
    # -------------------------------------------------------------------------
    #
    # supports Int64-column-vs-Int64-column AND Int64-column-
    # vs-Int64-literal comparisons. Float64 / String comparisons are
    # not supported. The comparison sub-op is in `node.extra` (CMP_*).
    # =========================================================================

    def _eval_comparison[W: Int](
        self,
        node: RuntimeNode,
        batch: BatchView,
        i: Int,
    ) raises -> EvalBoolChunk[W]:
        """Evaluate one RT_COMPARISON node — supports Int64 ops.

        Left child must be RT_COL_REF (Int64 column read);
        right child must be RT_COL_REF (Int64 column) OR RT_LIT_INT
        (immediate). Other shapes raise FALLBACK.

        Returns the per-lane comparison result with Kleene-aware
        validity (= `left.validity & right.validity` per
        `_cmp_result_validity_chunk`).
        """
        var left = self._node_at(node.left_idx, "_eval_comparison")
        var right = self._node_at(node.right_idx, "_eval_comparison")

        # Left must be a column ref.
        if left.tag != RT_COL_REF:
            raise Error(
                "RuntimeExprBool._eval_comparison: supports "
                + "only col_ref on the left; got tag "
                + String(Int(left.tag))
            )

        # Read the left Int64 column.
        var lcol = batch.col_i64(left.col_idx)
        var lvals = lcol.load[W](i)
        var lvalid = lcol.validity_load[W](i)

        # Right: column ref or Int64 literal.
        if right.tag == RT_COL_REF:
            var rcol = batch.col_i64(right.col_idx)
            var rvals = rcol.load[W](i)
            var rvalid = rcol.validity_load[W](i)
            var values = self._cmp_simd[W](node.extra, lvals, rvals)
            var validity = lvalid & rvalid
            return EvalBoolChunk[W](values=values, validity=validity)
        elif right.tag == RT_LIT_INT:
            var rsplat = SIMD[DType.int64, W](right.lit_int)
            var values = self._cmp_simd[W](node.extra, lvals, rsplat)
            # Right literal is always valid → result validity = left.
            return EvalBoolChunk[W](values=values, validity=lvalid)
        else:
            raise Error(
                "RuntimeExprBool._eval_comparison: supports "
                + "col_ref or lit_int on the right; got tag "
                + String(Int(right.tag))
            )

    @always_inline
    def _cmp_simd[W: Int](
        self,
        sub_op: UInt8,
        a: SIMD[DType.int64, W],
        b: SIMD[DType.int64, W],
    ) raises -> SIMD[DType.bool, W]:
        """Lane-wise comparison dispatch on the sub-op."""
        if sub_op == CMP_LT:
            return a.lt(b)
        elif sub_op == CMP_LE:
            return a.le(b)
        elif sub_op == CMP_GT:
            return a.gt(b)
        elif sub_op == CMP_GE:
            return a.ge(b)
        elif sub_op == CMP_EQ:
            return a.eq(b)
        elif sub_op == CMP_NE:
            return a.ne(b)
        else:
            raise Error(
                "RuntimeExprBool._cmp_simd: unknown sub_op "
                + String(Int(sub_op))
            )

    # -------------------------------------------------------------------------
    # Internal — RT_IS_NULL evaluator
    # -------------------------------------------------------------------------

    def _eval_is_null[W: Int](
        self,
        node: RuntimeNode,
        batch: BatchView,
        i: Int,
    ) raises -> EvalBoolChunk[W]:
        """Evaluate one RT_IS_NULL node — the child must be a column
        ref.

        IS_NULL semantics: result value = NOT validity; result is
        ALWAYS valid (IS_NULL is total — every input has a well-
        defined nullability).

        IS_NOT_NULL is the negation: result value = validity.

        A variant in `node.extra` other than ISNULL_IS_NULL /
        ISNULL_IS_NOT_NULL raises.
        """
        var child = self._node_at(node.left_idx, "_eval_is_null")
        if child.tag != RT_COL_REF:
            raise Error(
                "RuntimeExprBool._eval_is_null: supports only "
                + "col_ref child; got tag "
                + String(Int(child.tag))
            )
        if node.extra != ISNULL_IS_NULL and node.extra != ISNULL_IS_NOT_NULL:
            raise Error(
                "RuntimeExprBool._eval_is_null: unknown variant "
                + String(Int(node.extra))
            )

        # Use Int64 col reader to obtain validity (works for any
        # primitive column via the underlying validity bitmap; a
        # per-dtype specialization is possible).
        var col = batch.col_i64(child.col_idx)
        var v = col.validity_load[W](i)
        var all_true = SIMD[DType.bool, W](fill=True)
        if node.extra == ISNULL_IS_NULL:
            return EvalBoolChunk[W](values=~v, validity=all_true)
        # ISNULL_IS_NOT_NULL (any other variant raised above)
        return EvalBoolChunk[W](values=v, validity=all_true)

    # -------------------------------------------------------------------------
    # Internal — RT_BETWEEN evaluator
    # -------------------------------------------------------------------------

    def _eval_between[W: Int](
        self,
        node: RuntimeNode,
        batch: BatchView,
        i: Int,
    ) raises -> EvalBoolChunk[W]:
        """Evaluate one RT_BETWEEN node — `value BETWEEN low AND high`.

        Supports: value = col_ref Int64, low = lit_int OR
        col_ref Int64, high = lit_int OR col_ref Int64.

        Semantics: result = (value >= low) AND (value <= high).
        Validity per Kleene: result valid iff value.valid AND
        low.valid AND high.valid.
        """
        var value_node = self._node_at(node.left_idx, "_eval_between")
        var low_node = self._node_at(node.right_idx, "_eval_between")
        var high_node = self._node_at(node.third_idx, "_eval_between")

        if value_node.tag != RT_COL_REF:
            raise Error(
                "RuntimeExprBool._eval_between: supports only "
                + "col_ref on the value; got tag "
                + String(Int(value_node.tag))
            )

        var vcol = batch.col_i64(value_node.col_idx)
        var vvals = vcol.load[W](i)
        var vvalid = vcol.validity_load[W](i)

        # Read low.
        var low_vals: SIMD[DType.int64, W]
        var low_valid: SIMD[DType.bool, W]
        if low_node.tag == RT_LIT_INT:
            low_vals = SIMD[DType.int64, W](low_node.lit_int)
            low_valid = SIMD[DType.bool, W](fill=True)
        elif low_node.tag == RT_COL_REF:
            var lc = batch.col_i64(low_node.col_idx)
            low_vals = lc.load[W](i)
            low_valid = lc.validity_load[W](i)
        else:
            raise Error(
                "RuntimeExprBool._eval_between: low operand "
                + "must be lit_int or col_ref; got tag "
                + String(Int(low_node.tag))
            )

        # Read high.
        var high_vals: SIMD[DType.int64, W]
        var high_valid: SIMD[DType.bool, W]
        if high_node.tag == RT_LIT_INT:
            high_vals = SIMD[DType.int64, W](high_node.lit_int)
            high_valid = SIMD[DType.bool, W](fill=True)
        elif high_node.tag == RT_COL_REF:
            var hc = batch.col_i64(high_node.col_idx)
            high_vals = hc.load[W](i)
            high_valid = hc.validity_load[W](i)
        else:
            raise Error(
                "RuntimeExprBool._eval_between: high operand "
                + "must be lit_int or col_ref; got tag "
                + String(Int(high_node.tag))
            )

        var ge_low = vvals.ge(low_vals)
        var le_high = vvals.le(high_vals)
        var values = ge_low & le_high
        var validity = vvalid & low_valid & high_valid
        return EvalBoolChunk[W](values=values, validity=validity)


# =============================================================================
# Builder — manual entry
# =============================================================================
#
# This ships only `build_from_nodes` for tests + future
# planner integration. The planner-Expr-tree to runtime-tree
# translation logic is not implemented here.
# =============================================================================


def build_runtime_expr_bool(
    var nodes: List[RuntimeNode],
    root: Int,
) raises -> RuntimeExprBool:
    """Build a RuntimeExprBool from a List of nodes.

    Args:
        nodes: List of nodes in arbitrary order — `root` indexes into
            this list; children indexes refer to the same list.
        root: Index of the root node.

    Raises:
        Error if `len(nodes) > MAX_NODES` (overflow — NOT
        fill=False poison).
        Error if `root` is out of range.

    The unused slots above `len(nodes)` are filled with `_rt_sentinel`.
    """
    var n = len(nodes)
    if n > MAX_NODES:
        raise Error(
            "build_runtime_expr_bool: node count "
            + String(n)
            + " exceeds MAX_NODES="
            + String(MAX_NODES)
        )
    if root < 0 or root >= n:
        raise Error(
            "build_runtime_expr_bool: root "
            + String(root)
            + " out of bounds [0, "
            + String(n)
            + ")"
        )
    var arr = Array[RuntimeNode, MAX_NODES](fill=_rt_sentinel())
    for k in range(n):
        arr[k] = nodes[k]
    return RuntimeExprBool(nodes=arr^, node_count=n, root=root)
