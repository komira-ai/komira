# =============================================================================
# sql/sql_window_keys.mojo
#   Computed window keys: their hidden names, and the SELECTs that keep them.
# =============================================================================
#
# A window key that is not a plain column (`rank() OVER (ORDER BY count(*)
# DESC)`) is parsed as an expression and parked in the enclosing
# `SelectStmt.window_keys`; the window records its index there
# (`SqlWindowData.partition_key_expr` / `order_key_expr`) and the hidden name
# `_window_key_name(n)` in place of a column name.
#
# Such a key is served in a SELECT that aggregates (`_select_is_grouped`): the
# binder evaluates it with the groups and the window runs over the groups
# (`sql_bind_window_group`). In any other SELECT the parser refuses it by
# name, as it did before keys could be computed.
# =============================================================================

from sql.sql_ast import SelectStmt


comptime _WINDOW_KEY_PREFIX = "__window_key_"


def _window_key_name(n: Int) -> String:
    """The hidden column name of computed window key `n`."""
    return String(_WINDOW_KEY_PREFIX) + String(n)


def _select_is_grouped(stmt: SelectStmt) -> Bool:
    """True iff `stmt` aggregates its rows into groups: it has a GROUP BY or a
    HAVING, a SELECT item that is not a window contains an aggregate, or a
    computed window key does (`rank() OVER (ORDER BY count(*))` with no GROUP
    BY is one group of every row). The parser and the binder ask the same
    question: a computed window key is kept only in such a SELECT, and a
    window there runs over the groups."""
    if len(stmt.group_by) > 0 or Bool(stmt.having_pred):
        return True
    for i in range(len(stmt.select_items)):
        ref it = stmt.select_items[i]
        if not it.is_star and it.expr.contains_aggregate():
            return True
    for n in range(len(stmt.window_keys)):
        if stmt.window_keys[n].contains_aggregate():
            return True
    return False
