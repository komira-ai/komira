# =============================================================================
# expr_helpers -- Expr-pretty-printing + AND-tree flattening helpers
# =============================================================================
#
# Kept separate from `expr.mojo` to keep that file small.
#
# Public API (re-exported by `expr.mojo` for back-compat):
#   - `binop_name(op)` / `unop_name(op)` -- human-readable enum names.
#   - `flatten_and_conjuncts(expr)` -- AND-tree -> Slab[Expr] of leaves.
# =============================================================================

from ..collections.slab import Slab
from .expr import (
    Expr,
    EXPR_BINARY_OP,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_MOD,
    BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
    BIN_AND, BIN_OR,
    UN_NOT, UN_NEGATE, UN_IS_NULL, UN_IS_NOT_NULL,
    UN_ABS, UN_SIGN, UN_TRUNC, UN_ROUND, UN_BIT_COUNT,
    STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH, STR_LIKE,
)


# =============================================================================
# Convenience: binop_name / unop_name as String
# =============================================================================

def _write_binop_name[W: Writer](mut writer: W, op: UInt8):
    """WRITE what `binop_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, so a
    shared library can bind such a pair CROSSED and crash the host
    interpreter."""
    if op == BIN_ADD:
        writer.write("ADD")
        return
    elif op == BIN_SUB:
        writer.write("SUB")
        return
    elif op == BIN_MUL:
        writer.write("MUL")
        return
    elif op == BIN_DIV:
        writer.write("DIV")
        return
    elif op == BIN_MOD:
        writer.write("MOD")
        return
    elif op == BIN_EQ:
        writer.write("EQ")
        return
    elif op == BIN_NE:
        writer.write("NE")
        return
    elif op == BIN_LT:
        writer.write("LT")
        return
    elif op == BIN_LE:
        writer.write("LE")
        return
    elif op == BIN_GT:
        writer.write("GT")
        return
    elif op == BIN_GE:
        writer.write("GE")
        return
    elif op == BIN_AND:
        writer.write("AND")
        return
    elif op == BIN_OR:
        writer.write("OR")
        return
    else:
        writer.write("UNKNOWN")
        return


def binop_name(op: UInt8) -> String:
    """Return human-readable name for a BinOp constant."""
    var out = String()
    _write_binop_name(out, op)
    return out^


def _write_unop_name[W: Writer](mut writer: W, op: UInt8):
    """WRITE what `unop_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, so a
    shared library can bind such a pair CROSSED and crash the host
    interpreter."""
    if op == UN_NOT:
        writer.write("NOT")
        return
    elif op == UN_NEGATE:
        writer.write("NEGATE")
        return
    elif op == UN_IS_NULL:
        writer.write("IS_NULL")
        return
    elif op == UN_IS_NOT_NULL:
        writer.write("IS_NOT_NULL")
        return
    elif op == UN_ABS:
        writer.write("ABS")
        return
    elif op == UN_SIGN:
        writer.write("SIGN")
        return
    elif op == UN_TRUNC:
        writer.write("TRUNC")
        return
    elif op == UN_ROUND:
        writer.write("ROUND")
        return
    elif op == UN_BIT_COUNT:
        writer.write("BIT_COUNT")
        return
    else:
        writer.write("UNKNOWN")
        return


def unop_name(op: UInt8) -> String:
    """Return human-readable name for a UnOp constant."""
    var out = String()
    _write_unop_name(out, op)
    return out^


# =============================================================================
# flatten_and_conjuncts — split an AND-tree into a flat list of conjuncts
# =============================================================================
#

# `A AND (B AND C)` becomes `[A, B, C]`. Non-AND predicates pass through as
# a single-element array. Cost is proportional to the number of Expr nodes
# (tree walk), not data rows.
# =============================================================================


def _flatten_and_inner(expr: Expr, mut out: Slab[Expr]):
    """Recursive helper: walks AND-tree, appends non-AND leaves to `out`.

    Handles nested AND chains of arbitrary depth (left-skewed, right-skewed,
    or mixed). Non-AND nodes are treated as opaque conjuncts.
    """
    if expr.tag == EXPR_BINARY_OP and expr.binary_op() == BIN_AND:
        _flatten_and_inner(expr.binary_left_ref(), out)
        _flatten_and_inner(expr.binary_right_ref(), out)
    else:
        out.append(expr.copy())


# =============================================================================
# Writer-form pretty-printers for BinOp / UnOp / StringOp
# =============================================================================
#
# Used solely by `Expr.write_to`.
# =============================================================================


def _write_binop[W: Writer](mut writer: W, op: UInt8):
    """Write the human-readable name of a BinOp."""
    if op == BIN_ADD:
        writer.write("ADD")
    elif op == BIN_SUB:
        writer.write("SUB")
    elif op == BIN_MUL:
        writer.write("MUL")
    elif op == BIN_DIV:
        writer.write("DIV")
    elif op == BIN_MOD:
        writer.write("MOD")
    elif op == BIN_EQ:
        writer.write("EQ")
    elif op == BIN_NE:
        writer.write("NE")
    elif op == BIN_LT:
        writer.write("LT")
    elif op == BIN_LE:
        writer.write("LE")
    elif op == BIN_GT:
        writer.write("GT")
    elif op == BIN_GE:
        writer.write("GE")
    elif op == BIN_AND:
        writer.write("AND")
    elif op == BIN_OR:
        writer.write("OR")
    else:
        writer.write("UNKNOWN(", Int(op), ")")


def _write_unop[W: Writer](mut writer: W, op: UInt8):
    """Write the human-readable name of a UnOp."""
    if op == UN_NOT:
        writer.write("NOT")
    elif op == UN_NEGATE:
        writer.write("NEGATE")
    elif op == UN_IS_NULL:
        writer.write("IS_NULL")
    elif op == UN_IS_NOT_NULL:
        writer.write("IS_NOT_NULL")
    elif op == UN_ABS:
        writer.write("ABS")
    elif op == UN_SIGN:
        writer.write("SIGN")
    elif op == UN_TRUNC:
        writer.write("TRUNC")
    elif op == UN_ROUND:
        writer.write("ROUND")
    elif op == UN_BIT_COUNT:
        writer.write("BIT_COUNT")
    else:
        writer.write("UNKNOWN(", Int(op), ")")


def _write_strop[W: Writer](mut writer: W, op: UInt8):
    """Write the human-readable name of a StringOp."""
    if op == STR_CONTAINS:
        writer.write("CONTAINS")
    elif op == STR_STARTS_WITH:
        writer.write("STARTS_WITH")
    elif op == STR_ENDS_WITH:
        writer.write("ENDS_WITH")
    elif op == STR_LIKE:
        writer.write("LIKE")
    else:
        writer.write("UNKNOWN(", Int(op), ")")


def flatten_and_conjuncts(expr: Expr) -> Slab[Expr]:
    """Flatten an AND-tree into a flat list of conjuncts.

    `AND(AND(A, B), C)` flattens to `[A, B, C]`. Non-AND expressions are
    returned as a single-element array.

    Args:
        expr: The predicate expression tree to flatten.

    Returns:
        A `Slab[Expr]` containing deep copies of every non-AND node
        reachable through the AND-subtree rooted at `expr`. The input is
        unchanged.
    """
    var out = Slab[Expr]()
    _flatten_and_inner(expr, out)
    return out^
