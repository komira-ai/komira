# =============================================================================
# fn_rel_args.mojo — the AST-shaped ARGUMENT parsing the relation verbs share
# =============================================================================
#
# THREE HELPERS, SEVEN CALLERS, ONE SPELLING EACH. Every relation-returning
# Excel verb (`fn_rel_dynarray`'s FILTER / SORT / UNIQUE / CHOOSECOLS / GROUPBY /
# TAKE and the SUM|COUNT(FILTER(...)) fusion) starts by reading the SAME two
# kinds of argument off the `FormulaAst`: a NAME bound to a relation, and an
# integer LITERAL. This module owns both, plus the `SORT` optional-argument pair
# built from them.
#
# ⚠ THE DEPENDENCY DIRECTION IS THE INVARIANT: `fn_rel_dynarray -> fn_rel_args`,
# and `fn_rel_args` imports NO sibling `fn_rel_*` module. That is what keeps the
# extraction free of a cycle — `fn_rel_order` and `fn_rel_groupby` take
# ALREADY-PARSED values, so neither needs this and neither may import it back.
# =============================================================================

from .formula_ast import (
    FormulaAst,
    NODE_NAME,
    NODE_NUMBER,
    NODE_UNARY,
    OP_NEG,
)
from .formula_bindings import FormulaBindings
from .bound_relation import BoundRelation


def _bound_array(
    src: FormulaAst, arg_idx: Int, bindings: FormulaBindings
) raises -> Optional[BoundRelation]:
    """Resolve an `array` argument node to its bound relation, or None if the arg is
    not a NAME bound to a relation (out of envelope).

    ON THE NAMED ARM THE RESIDENT BATCH IS A ZERO-ROW, ZERO-COLUMN PLACEHOLDER,
    so an unguarded `UNIQUE(ord)` over a file-backed table would spill #CALC!
    (empty) rather than the de-duplicated table. A confident empty answer is
    worse than a refusal."""
    var a = src.get(arg_idx)
    if a.tag != NODE_NAME:
        return Optional[BoundRelation]()
    return bindings.lookup_relation(a.text)


struct _SortSpec(Copyable, Movable):
    """SORT's two optional arguments, parsed: a 1-based column POSITION and a
    direction."""

    var index: Int
    var descending: Bool

    def __init__(out self, index: Int, descending: Bool):
        self.index = index
        self.descending = descending


def _sort_spec(src: FormulaAst, args: List[Int]) raises -> Optional[_SortSpec]:
    """Parse `SORT(array, [sort_index], [sort_order])`'s OPTIONAL arguments —
    `args` is the SORT call's own argument list and `args[0]` (the array) is not
    read here. `sort_index` defaults to 1 (Excel's default); `sort_order` is 1
    (ascending, the default) or -1 (descending) and NOTHING else.

    Returns None for any out-of-envelope argument — a non-literal index or
    order, or an order outside {1, -1} — which every caller turns into a SCALAR
    `#VALUE!`.

    ⚠ IT IS ONE PARSE FOR TWO CALLERS ON PURPOSE. `lower_sort` reads these
    arguments and so does `lower_take`, for the `TAKE(SORT(...), n)` composition
    the corpus's Q07 needs. A second spelling of the `-1` rule in a sibling verb
    is a place for the two to drift — the same reason `fn_rel_groupby.
    _resolve_position` names the drift it was extracted to prevent — and here
    the drift would be SILENT: `TAKE(SORT(ord, 3, -1), 3)` and
    `SORT(ord, 3, -1)` returning rows ordered two different ways is a wrong
    answer, not an error."""
    var index = 1
    if len(args) >= 2:
        var iv = _int_literal(src, args[1])
        if not iv:
            return Optional[_SortSpec]()
        index = iv.value()
    var descending = False
    if len(args) >= 3:
        var ov = _int_literal(src, args[2])
        if not ov:
            return Optional[_SortSpec]()
        var order = ov.value()
        if order == -1:
            descending = True
        elif order != 1:
            return Optional[_SortSpec]()
    return Optional[_SortSpec](_SortSpec(index, descending))



def _int_literal(src: FormulaAst, idx: Int) -> Optional[Int]:
    """Evaluate a SORT `sort_index` / `sort_order` argument that must be an integer
    LITERAL (a NODE_NUMBER, or a unary-minus over one — `-1` parses as NEG(1)).
    Returns None for any non-literal arg (out of envelope)."""
    var n = src.get(idx)
    if n.tag == NODE_NUMBER:
        return Optional[Int](Int(n.num))
    if n.tag == NODE_UNARY and n.op == OP_NEG:
        var c = src.get(n.left)
        if c.tag == NODE_NUMBER:
            return Optional[Int](-Int(c.num))
    return Optional[Int]()
