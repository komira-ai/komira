# =============================================================================
# viewport_expr_codec.mojo — viewport-protocol Expr tree wire serialization (the v1 allow-list).
# =============================================================================
#
# Plans are in-process Mojo structs; this module is their versioned Expr
# wire encoder/decoder. A round-trip is the property it is held to:
#   Expr -> encode_expr -> bytes -> decode_expr -> Expr'  with
#   Expr.structural_hash() == Expr'.structural_hash()  (identical plan hash).
#
# THE ALLOW-LIST (the security spine). The full komira_plan_expr Expr surface has
# ~23 variant tags (agg-fn, window-fn, correlated-subquery, regexp, UDF,
# json_extract, struct/map projection, ...). viewport protocol v1 serializes ONLY the SIX
# grid-filter / sort / computed-column tags:
#
#   EXPR_COL_REF   — a column reference          (filter/sort/project leaf)
#   EXPR_LITERAL   — a scalar constant           (filter RHS)
#   EXPR_BINARY_OP — arithmetic / compare / bool (the predicate + math spine)
#   EXPR_UNARY_OP  — NOT / NEGATE / IS NULL      (predicate negation + null test)
#   EXPR_STRING_OP — contains/starts/ends/LIKE   (text-column filters)
#   EXPR_ALIAS     — named computed column       (with_column projection)
#
# EVERY OTHER TAG IS REJECTED by both `encode_expr` (so a server never emits a
# non-round-trippable tree) AND `decode_expr` (so an untrusted remote ticket
# carrying an agg-fn / window-fn / UDF / correlated-subquery / regexp node is
# rejected fail-closed — named work (b), the hostile-ticket boundary). UDF
# references live under EXPR_AGG_FN / scalar-UDF descriptors, all outside the
# allow-list, so "reject UDF references unless allow-listed" is satisfied by
# construction: the v1 allow-list contains no UDF-bearing tag.
#
# DEPTH GUARD. `decode_expr` carries a remaining-depth budget; a ticket whose
# Expr tree nests past VIEWPORT_MAX_EXPR_DEPTH raises BEFORE unbounded recursion —
# a remote client cannot blow the worker stack with a pathologically deep tree.
#
# Encapsulation: pure value logic over `Expr` + `ViewportWriter`/`ViewportReader`. No
# UnsafePointer crosses the boundary. Mojo 1.0.0b2 (def-only).
# =============================================================================

from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_STRING_OP,
    EXPR_ALIAS,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_MOD,
    BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
    BIN_AND, BIN_OR,
    UN_NOT, UN_NEGATE, UN_IS_NULL, UN_IS_NOT_NULL,
    STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH, STR_LIKE,
    COL_SIDE_NONE, COL_SIDE_LEFT, COL_SIDE_RIGHT,
)

from .viewport_bytes import ViewportWriter, ViewportReader


# The Expr-tree nesting cap enforced on DECODE (untrusted input). 64 comfortably
# covers any realistic hand-built grid predicate (a 64-deep AND chain is 64
# ANDed clauses) while bounding recursion / stack use on a hostile ticket.
comptime VIEWPORT_MAX_EXPR_DEPTH: Int = 64


# --- viewport-protocol scalar-literal wire tags (the ScalarValue discriminant on the wire) --
comptime VIEWPORT_SCALAR_NULL: UInt8 = 0      # untyped NULL (ScalarValue() default)
comptime VIEWPORT_SCALAR_BOOL: UInt8 = 1
comptime VIEWPORT_SCALAR_INT64: UInt8 = 2
comptime VIEWPORT_SCALAR_INT32: UInt8 = 3
comptime VIEWPORT_SCALAR_FLOAT64: UInt8 = 4
comptime VIEWPORT_SCALAR_FLOAT32: UInt8 = 5
comptime VIEWPORT_SCALAR_STRING: UInt8 = 6


def _is_allowed_binop(op: UInt8) -> Bool:
    """The 14 binary op codes viewport protocol v1 permits (arithmetic + compare + bool)."""
    return (
        op == BIN_ADD or op == BIN_SUB or op == BIN_MUL or op == BIN_DIV
        or op == BIN_MOD or op == BIN_EQ or op == BIN_NE or op == BIN_LT
        or op == BIN_LE or op == BIN_GT or op == BIN_GE or op == BIN_AND
        or op == BIN_OR
    )


def _is_allowed_unop(op: UInt8) -> Bool:
    """The 4 unary op codes viewport protocol v1 permits."""
    return (
        op == UN_NOT or op == UN_NEGATE or op == UN_IS_NULL
        or op == UN_IS_NOT_NULL
    )


def _is_allowed_strop(op: UInt8) -> Bool:
    """The 4 string op codes viewport protocol v1 permits."""
    return (
        op == STR_CONTAINS or op == STR_STARTS_WITH or op == STR_ENDS_WITH
        or op == STR_LIKE
    )


def _is_allowed_side(side: UInt8) -> Bool:
    return side == COL_SIDE_NONE or side == COL_SIDE_LEFT or side == COL_SIDE_RIGHT


# =============================================================================
# ScalarValue codec.
# =============================================================================


def encode_scalar(mut w: ViewportWriter, sv: ScalarValue) raises:
    """Encode a ScalarValue as one viewport-protocol scalar tag + its payload.

    Supports the DType-family literals (null / bool / int64 / int32 / float64 /
    float32 / string). DECIMAL128 / DATE32 / TIMESTAMP literals are reserved for
    v1.1 and RAISE here (a server never builds them; a client cannot post them)."""
    if sv.is_null():
        w.write_u8(VIEWPORT_SCALAR_NULL)
        return
    if sv.is_bool():
        w.write_u8(VIEWPORT_SCALAR_BOOL)
        w.write_bool(sv.bool_val)
        return
    if sv.is_int():
        if sv.dtype == DType.int32:
            w.write_u8(VIEWPORT_SCALAR_INT32)
        else:
            w.write_u8(VIEWPORT_SCALAR_INT64)
        w.write_ivarint(sv.int_val)
        return
    if sv.is_float():
        if sv.dtype == DType.float32:
            w.write_u8(VIEWPORT_SCALAR_FLOAT32)
            w.write_f32(Float32(sv.float_val))
        else:
            w.write_u8(VIEWPORT_SCALAR_FLOAT64)
            w.write_f64(sv.float_val)
        return
    if sv.is_string():
        w.write_u8(VIEWPORT_SCALAR_STRING)
        w.write_string(sv.string_val)
        return
    raise Error(
        "viewport: literal scalar kind not supported in viewport protocol v1 "
        "(decimal128 / date32 / timestamp are reserved for v1.1)"
    )


def decode_scalar(mut r: ViewportReader) raises -> ScalarValue:
    """Decode one viewport-protocol scalar tag + payload back into a ScalarValue. Raises on an
    unknown scalar tag (fail-closed)."""
    var tag = r.read_u8()
    if tag == VIEWPORT_SCALAR_NULL:
        return ScalarValue()
    if tag == VIEWPORT_SCALAR_BOOL:
        return ScalarValue.from_bool(r.read_bool())
    if tag == VIEWPORT_SCALAR_INT64:
        return ScalarValue.from_int64(r.read_ivarint())
    if tag == VIEWPORT_SCALAR_INT32:
        return ScalarValue.from_int32(Int32(r.read_ivarint()))
    if tag == VIEWPORT_SCALAR_FLOAT64:
        return ScalarValue.from_float(r.read_f64())
    if tag == VIEWPORT_SCALAR_FLOAT32:
        return ScalarValue.from_float32(r.read_f32())
    if tag == VIEWPORT_SCALAR_STRING:
        return ScalarValue.from_string(r.read_string())
    raise Error("viewport: unknown scalar tag " + String(Int(tag)))


# =============================================================================
# Expr codec.
# =============================================================================


def encode_expr(mut w: ViewportWriter, e: Expr) raises:
    """Serialize an Expr subtree. RAISES on any tag outside the v1 allow-list —
    a server must never emit a tree it cannot round-trip (and this doubles as the
    encoder-side guard that the plan it built from a validated ticket stayed
    inside the allow-list)."""
    var tag = e.tag
    w.write_u8(tag)
    if tag == EXPR_COL_REF:
        w.write_string(e.col_ref_name())
        w.write_u8(e.col_ref_side())
        return
    if tag == EXPR_LITERAL:
        encode_scalar(w, e.literal_value())
        return
    if tag == EXPR_BINARY_OP:
        w.write_u8(e.binary_op())
        encode_expr(w, e.binary_left_ref())
        encode_expr(w, e.binary_right_ref())
        return
    if tag == EXPR_UNARY_OP:
        w.write_u8(e.unary_op())
        encode_expr(w, e.unary_child_ref())
        return
    if tag == EXPR_STRING_OP:
        w.write_u8(e.string_op_type())
        encode_expr(w, e.string_op_child_ref())
        w.write_string(e.string_op_pattern())
        return
    if tag == EXPR_ALIAS:
        w.write_string(e.alias_name())
        encode_expr(w, e.alias_child_ref())
        return
    raise Error(
        "viewport: Expr tag "
        + String(Int(tag))
        + " is not in the viewport protocol v1 allow-list (agg-fn / window-fn / "
        "correlated-subquery / regexp / UDF / cast / in-list / nested "
        "projections are rejected)"
    )


def decode_expr(mut r: ViewportReader) raises -> Expr:
    """Top-level Expr decode with the full depth budget."""
    return _decode_expr_depth(r, VIEWPORT_MAX_EXPR_DEPTH)


def _decode_expr_depth(mut r: ViewportReader, depth_left: Int) raises -> Expr:
    """Recursive Expr decode with a remaining-depth budget. RAISES on:
      * an Expr tag outside the v1 allow-list (hostile-ticket rejection),
      * a disallowed op code inside an allowed tag,
      * exceeding VIEWPORT_MAX_EXPR_DEPTH (deep-tree stack-exhaustion defense),
      * any malformed / truncated byte (via the strict ViewportReader)."""
    if depth_left <= 0:
        raise Error(
            "viewport: Expr tree exceeds max depth "
            + String(VIEWPORT_MAX_EXPR_DEPTH)
            + " (rejected)"
        )
    var tag = r.read_u8()
    if tag == EXPR_COL_REF:
        var name = r.read_string()
        var side = r.read_u8()
        # Reconstruct through the public factories so the (name, side) pair
        # round-trips faithfully without touching private variant fields.
        if side == COL_SIDE_LEFT:
            return Expr.left(name)
        if side == COL_SIDE_RIGHT:
            return Expr.right(name)
        if side != COL_SIDE_NONE:
            raise Error("viewport: illegal col-ref side qualifier " + String(Int(side)))
        return Expr.col_ref(name)
    if tag == EXPR_LITERAL:
        return Expr.literal(decode_scalar(r))
    if tag == EXPR_BINARY_OP:
        var op = r.read_u8()
        if not _is_allowed_binop(op):
            raise Error("viewport: disallowed binary op code " + String(Int(op)))
        var left = _decode_expr_depth(r, depth_left - 1)
        var right = _decode_expr_depth(r, depth_left - 1)
        return Expr.binary(op, left^, right^)
    if tag == EXPR_UNARY_OP:
        var op = r.read_u8()
        if not _is_allowed_unop(op):
            raise Error("viewport: disallowed unary op code " + String(Int(op)))
        var child = _decode_expr_depth(r, depth_left - 1)
        return Expr.unary(op, child^)
    if tag == EXPR_STRING_OP:
        var op = r.read_u8()
        if not _is_allowed_strop(op):
            raise Error("viewport: disallowed string op code " + String(Int(op)))
        var child = _decode_expr_depth(r, depth_left - 1)
        var pattern = r.read_string()
        return Expr.string_op(op, child^, pattern)
    if tag == EXPR_ALIAS:
        var name = r.read_string()
        var child = _decode_expr_depth(r, depth_left - 1)
        return Expr.alias(child^, name)
    raise Error(
        "viewport: Expr tag "
        + String(Int(tag))
        + " is not in the viewport protocol v1 allow-list — rejected (a ticket may carry "
        "only col-ref / literal / binary-op / unary-op / string-op / alias "
        "nodes; agg-fn / window-fn / UDF / correlated-subquery / regexp are "
        "forbidden)"
    )
