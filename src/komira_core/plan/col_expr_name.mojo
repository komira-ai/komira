# =============================================================================
# col_expr_name — polars' `Expr.name` namespace on the untyped Mojo door:
# `col("v").name().prefix("p_")` / `.suffix("_x")`.
# =============================================================================
#
# polars renames an expression's OUTPUT by its CURRENT name: `pl.col("v")
# .name.suffix("_x")` is `v_x`, `pl.col("v").alias("w").name.suffix("_x")` is
# `w_x` (both MEASURED, polars 1.44.2). SQL has no such verb; the SQL door
# answers the same question with `v AS v_x`, which is exactly the tree built
# here: an ALIAS over the unchanged expression.
#
# ⛔ A COMPUTED RECEIVER RAISES BY NAME. polars names `(col("v") * 2)` after
# its ROOT column (`v_x`); this door's computed expressions take the engine's
# generated name, so there is no "current name" to
# extend that polars would agree with. Alias the expression first.
# `name()` is a method, not polars' attribute, because Mojo has no property
# returning a namespace here; the verbs after it are polars'.
# =============================================================================

from .expr import Expr


struct ColExprNames(Movable):
    """The `.name()` namespace of a `ColExpr`: renames of its output."""

    var _expr: Expr

    def __init__(out self, var expr: Expr):
        self._expr = expr^

    def _current_name(self, verb: String) raises -> String:
        if self._expr.is_col_ref():
            return self._expr.col_ref_name()
        if self._expr.is_alias():
            return self._expr.alias_name()
        raise Error(
            "name()." + verb + "(): the receiver has no name of its own — it"
            " is a computed expression, which polars names after its ROOT"
            " column and this door after the engine's generated name. Alias"
            " it first: `(col(\"v\") * 2).alias(\"v2\")`."
        )

    def prefix(self, prefix: String) raises -> Expr:
        """polars `name.prefix(p)`: `p + <current name>`."""
        var n = prefix + self._current_name("prefix")
        return Expr.alias(_unaliased(self._expr), n)

    def suffix(self, suffix: String) raises -> Expr:
        """polars `name.suffix(s)`: `<current name> + s`."""
        var n = self._current_name("suffix") + suffix
        return Expr.alias(_unaliased(self._expr), n)


def _unaliased(e: Expr) -> Expr:
    """The expression under ONE alias (a re-alias replaces the name rather
    than stacking two aliases), else the expression itself."""
    if e.is_alias():
        return e.alias_child_ref().copy()
    return e.copy()
