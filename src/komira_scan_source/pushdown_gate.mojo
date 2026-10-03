# =============================================================================
# PushdownGate — declarative filter-pushdown capability on a `ScanBinding`.
# =============================================================================
#
# THE RULE THIS FILE EXISTS TO ENFORCE:
#
#       CAPABILITY BITS ON THE NODE; CALLBACKS IN THE REGISTRY.
#
# `SourceLike.supports_filter_pushdown(predicate) -> Bool` is a FUNCTION OF THE
# PREDICATE. Pure data cannot call a function, so this is exactly where a naive
# design reaches for a fn-ptr field on the plan node. That is banned (the only
# fn-ptr field allowed is FFI-POD) and, more decisively, a fn-ptr on the node
# would make the plan NON-SERIALIZABLE.
#
# Across all 9 union arms, the behaviour space collapses to THREE:
#
#   REJECT_ALL   json, csv, arrow x3, orc, avro  (7 arms)  -> trait default
#   ACCEPT_ALL   in_memory                       (1 arm)   -> `return True`
#   SHAPED       parquet                         (1 arm)   -> a recursive
#                classifier that factors cleanly into (a) a finite shape
#                grammar over Expr tags/ops and (b) a column test that is
#                derivable ENTIRELY from the schema the binding already
#                carries.
#
# `gate_allows` below is (a) + (b) evaluated by core against pure data. It is a
# behaviour-preserving generalisation of `ParquetSource._pushdown_supported`
# (parquet_source.mojo), not a new policy.
#
# A GENUINELY NOVEL GRAMMAR still has an escape hatch — a `classify` hook — but
# it is a REGISTRY ENTRY OWNED BY THE SOURCE'S PACKAGE, never a field on the
# plan node. The node stays serializable; the callback lives where the concrete
# types already are.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_IN_LIST,
    EXPR_LITERAL,
    BIN_AND,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    COL_SIDE_NONE,
)


comptime GATE_REJECT_ALL: UInt8 = 0
comptime GATE_ACCEPT_ALL: UInt8 = 1
comptime GATE_SHAPED: UInt8 = 2


def arrow_type_has_column_stats(t: ArrowType) -> Bool:
    """True if a column of Arrow type `t` carries scalar min/max statistics
    that a `col <op> literal` predicate can drive pruning from.

    ⚠ THIS IS THE ONE DEFINITION. `ParquetSource._arrow_type_has_parquet_stats`
    delegates here rather than keeping a private copy — a second copy would
    let the gate and the concrete source drift, and a gated arm must answer
    IDENTICALLY to the concrete source. Nested / dictionary / list / struct /
    map types do not qualify: there is no scalar min/max in a parquet footer
    the RG-pruning code reads.
    """
    return (
        t == ArrowType.BOOL
        or t == ArrowType.INT8
        or t == ArrowType.INT16
        or t == ArrowType.INT32
        or t == ArrowType.INT64
        or t == ArrowType.UINT8
        or t == ArrowType.UINT16
        or t == ArrowType.UINT32
        or t == ArrowType.UINT64
        or t == ArrowType.FLOAT16
        or t == ArrowType.FLOAT32
        or t == ArrowType.FLOAT64
        or t == ArrowType.STRING
        or t == ArrowType.LARGE_STRING
        or t == ArrowType.DATE32
        or t == ArrowType.DATE64
        or t == ArrowType.TIMESTAMP
        or t == ArrowType.TIMESTAMP_S
        or t == ArrowType.TIMESTAMP_MS
        or t == ArrowType.TIMESTAMP_US
        or t == ArrowType.TIMESTAMP_NS
        or t == ArrowType.DECIMAL128
    )


# Bit positions in `PushdownGate.allowed_binary_ops`. These are a LOCAL
# vocabulary, deliberately NOT `1 << BIN_*` — the `BIN_*` numeric values are an
# unrelated enumeration and coupling a persisted capability mask to them would
# make a future `BIN_*` renumber silently change every stored gate.
comptime GATE_OP_EQ: UInt32 = 1 << 0
comptime GATE_OP_NE: UInt32 = 1 << 1
comptime GATE_OP_LT: UInt32 = 1 << 2
comptime GATE_OP_LE: UInt32 = 1 << 3
comptime GATE_OP_GT: UInt32 = 1 << 4
comptime GATE_OP_GE: UInt32 = 1 << 5

comptime GATE_OPS_COMPARISON: UInt32 = (
    GATE_OP_EQ | GATE_OP_NE | GATE_OP_LT | GATE_OP_LE | GATE_OP_GT | GATE_OP_GE
)


@always_inline
def _gate_bit_for_binary_op(op: UInt8) -> UInt32:
    """Map a `BIN_*` op onto its gate bit; 0 for ops with no bit (which the
    caller must read as "not allowed", never as "allowed")."""
    if op == BIN_EQ:
        return GATE_OP_EQ
    elif op == BIN_NE:
        return GATE_OP_NE
    elif op == BIN_LT:
        return GATE_OP_LT
    elif op == BIN_LE:
        return GATE_OP_LE
    elif op == BIN_GT:
        return GATE_OP_GT
    elif op == BIN_GE:
        return GATE_OP_GE
    return UInt32(0)


@fieldwise_init
struct PushdownGate(Copyable, Movable, Deinitable):
    """Declarative pushdown capability — pure data, evaluated by `gate_allows`.

    NO callback, NO fn-ptr, NO concrete source reachable from the plan node.
    """

    var mode: UInt8
    """GATE_REJECT_ALL / GATE_ACCEPT_ALL / GATE_SHAPED."""

    var allowed_binary_ops: UInt32
    """Bitmask over GATE_OP_*. Meaningful only for GATE_SHAPED."""

    var allow_and_recurse: Bool
    """Whether `a AND b` is pushable when both sides are. (`OR` is never
    pushable in any in-tree source; a source that wants it needs a registry
    hook, not a bit — accepting an OR-tree changes the pruning semantics, not
    just the shape)."""

    var allow_in_list: Bool
    """Whether `col IN (...)` over an accepted column is pushable."""

    var require_stat_friendly_col: Bool
    """Whether a column must carry statistics to be pushable. When False, any
    column present in the binding's schema qualifies — the shape most non-file
    sources (broker offset ranges, search field filters) want."""

    def copy(self) -> Self:
        return Self(
            mode=self.mode,
            allowed_binary_ops=self.allowed_binary_ops,
            allow_and_recurse=self.allow_and_recurse,
            allow_in_list=self.allow_in_list,
            require_stat_friendly_col=self.require_stat_friendly_col,
        )

    @staticmethod
    def reject_all() -> Self:
        """The trait default — 7 of the 9 union arms."""
        return Self(
            mode=GATE_REJECT_ALL,
            allowed_binary_ops=UInt32(0),
            allow_and_recurse=False,
            allow_in_list=False,
            require_stat_friendly_col=False,
        )

    @staticmethod
    def accept_all() -> Self:
        """`InMemorySource` — every predicate becomes a deferred OP_FILTER."""
        return Self(
            mode=GATE_ACCEPT_ALL,
            allowed_binary_ops=UInt32(0),
            allow_and_recurse=False,
            allow_in_list=False,
            require_stat_friendly_col=False,
        )

    @staticmethod
    def conjunctive_comparison(require_stat_friendly_col: Bool = True) -> Self:
        """The zonemap family: `AND`-trees of comparisons against literals,
        plus `IN`-lists. Exactly `ParquetSource._pushdown_supported`, and the
        shape DataFusion `TableProvider`, Iceberg, Delta, broker offset ranges
        and search field filters all implement."""
        return Self(
            mode=GATE_SHAPED,
            allowed_binary_ops=GATE_OPS_COMPARISON,
            allow_and_recurse=True,
            allow_in_list=True,
            require_stat_friendly_col=require_stat_friendly_col,
        )

    def render(self) -> String:
        if self.mode == GATE_REJECT_ALL:
            return String("reject_all")
        elif self.mode == GATE_ACCEPT_ALL:
            return String("accept_all")
        return String("shaped(ops=") + String(self.allowed_binary_ops) + String(")")

    def hash_into(self, seed: UInt64) -> UInt64:
        """Fold the gate into an identity hash. Included so two bindings that
        differ ONLY in declared capability do not collide in a plan cache whose
        compiled plan depends on which conjuncts were pushed."""
        comptime prime = UInt64(1099511628211)
        var h = (seed ^ UInt64(self.mode)) * prime
        h = (h ^ UInt64(self.allowed_binary_ops)) * prime
        var flags = UInt64(0)
        if self.allow_and_recurse:
            flags |= UInt64(1)
        if self.allow_in_list:
            flags |= UInt64(2)
        if self.require_stat_friendly_col:
            flags |= UInt64(4)
        return (h ^ flags) * prime


# =============================================================================
# The matcher — core-resident, evaluated against (gate, schema, predicate).
# =============================================================================
#
# `stat_friendly_names` is the extra column vocabulary a kind may declare
# beyond its schema (parquet's Hive partition columns are the in-tree case: a
# partition predicate is consumed by `partition_prune_scans` regardless of the
# inferred partition-col type, so those names are accepted unconditionally).
# It is a `List[String]` — data, carried on the binding, not a callback.


def _col_is_pushable(
    gate: PushdownGate,
    schema: Schema,
    extra_names: List[String],
    e: Expr,
) -> Bool:
    """The COLUMN TEST — factor (b). Bare `COL_SIDE_NONE` col-ref present in
    the schema (with a stats-carrying type when the gate demands one) or in the
    kind's extra column vocabulary.

    Mirrors `ParquetSource._is_stat_friendly_colref` (parquet_source.mojo).
    """
    if e.tag != EXPR_COL_REF:
        return False
    if e.col_ref_side() != COL_SIDE_NONE:
        return False
    var name = e.col_ref_name()
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            if not gate.require_stat_friendly_col:
                return True
            return arrow_type_has_column_stats(schema.field_arrow_type(i))
    for i in range(len(extra_names)):
        if extra_names[i] == name:
            return True
    return False


def _col_op_literal(
    gate: PushdownGate,
    schema: Schema,
    extra_names: List[String],
    lhs: Expr,
    rhs: Expr,
) -> Bool:
    """True iff `lhs` is a pushable col-ref and `rhs` is a literal."""
    if rhs.tag != EXPR_LITERAL:
        return False
    return _col_is_pushable(gate, schema, extra_names, lhs)


def gate_allows(
    gate: PushdownGate,
    schema: Schema,
    extra_names: List[String],
    predicate: Expr,
) -> Bool:
    """THE plan-time pushdown answer, computed from pure data.

    Behaviour-preserving generalisation of the three in-tree behaviours:
      * GATE_REJECT_ALL -> False for every predicate (trait default).
      * GATE_ACCEPT_ALL -> True for every predicate (`InMemorySource`).
      * GATE_SHAPED     -> the shape grammar, byte-for-byte the parquet
                           classifier when constructed via
                           `PushdownGate.conjunctive_comparison()`.
    """
    if gate.mode == GATE_REJECT_ALL:
        return False
    if gate.mode == GATE_ACCEPT_ALL:
        return True

    # GATE_SHAPED — factor (a), the shape grammar.
    if predicate.tag == EXPR_BINARY_OP:
        var op = predicate.binary_op()
        if op == BIN_AND:
            if not gate.allow_and_recurse:
                return False
            return gate_allows(
                gate, schema, extra_names, predicate.binary_left_ref()
            ) and gate_allows(
                gate, schema, extra_names, predicate.binary_right_ref()
            )
        var bit = _gate_bit_for_binary_op(op)
        if bit == UInt32(0) or (gate.allowed_binary_ops & bit) == UInt32(0):
            # Arithmetic / OR / anything without a bit: not a pushable shape.
            return False
        # Comparison: one side a pushable col-ref, the other a literal
        # (order-insensitive, matching the parquet classifier).
        return _col_op_literal(
            gate,
            schema,
            extra_names,
            predicate.binary_left_ref(),
            predicate.binary_right_ref(),
        ) or _col_op_literal(
            gate,
            schema,
            extra_names,
            predicate.binary_right_ref(),
            predicate.binary_left_ref(),
        )
    elif predicate.tag == EXPR_IN_LIST:
        if not gate.allow_in_list:
            return False
        return _col_is_pushable(
            gate, schema, extra_names, predicate.in_list_child_ref()
        )
    # Bare col-ref / literal / unary / cast / string-op / between / when / agg
    # / window / correlated-subquery / col-idx: not a pushable conjunct alone.
    return False
