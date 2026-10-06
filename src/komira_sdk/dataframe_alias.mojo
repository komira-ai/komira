# =============================================================================
# dataframe_alias -- DataFrame.with_alias() free-function body
# =============================================================================
#
# Track A (ratified
# v0.4 scope): an explicit `df.with_alias("ns")` API that
# rewrites the DataFrame's output schema by prefixing every column name
# with `"ns."`. Closes the same-source self-join API friction
# (auto-`_right`-suffix order-sensitivity) flagged by the Q7 natural-shape
# rewrite question.
#
# Implementation strategy: pure schema rewrite via a Project node. The
# returned DataFrame has the SAME logical row content as the input, with
# columns renamed:
#
#     df.read_parquet("nation.parquet")     -> [n_nationkey, n_name, ...]
#     df.read_parquet(...).with_alias("supp_nation")
#                                           -> [supp_nation.n_nationkey,
#                                                supp_nation.n_name, ...]
#
# Downstream ops reference the prefixed names directly:
#
#     .inner_join(other, left_keys=["s_nationkey"],
#                        right_keys=["supp_nation.n_nationkey"])
#     .group_by("supp_nation.n_name")
#     .filter(col("supp_nation.n_name") == String("FRANCE"))
#
# Mojo's Schema field-name strings are unconstrained (no validation
# against `.`), and `compiler_helpers.resolve_col_index` /
# `Schema.column_index` are pure exact-name matches. So dotted names
# Just Work end-to-end -- no plan IR changes, no compiler changes.
#
# The natural-shape Q7 collision case (two `nation.parquet` instances
# joined into the same plan) is solved by giving each instance a
# distinct alias before the join. Because every field name is now
# unique across the merged schema (`supp_nation.n_name` vs
# `cust_nation.n_name`), the auto-`_right`-suffix logic in
# `_infer_join_schema` (schema_propagation.mojo:200-214) never fires.
#
# Interaction with existing `_right` collision rule: if the user does
# NOT alias both sides and a plain self-join happens, the suffix rule
# still fires (back-compat). `with_alias` is purely opt-in.
#
# Pattern matches Polars's `pl.col(...).alias()` and pandas's column-
# rename idiom; same role as DuckDB's table-aliased column references
# (`SELECT n1.n_name FROM nation n1 JOIN nation n2 ...`).
# =============================================================================

from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray
from komira_scan_source.compiler_registry import InMemoryRegistry


# =============================================================================
# _BuiltAlias -- (plan, registry, cnt) bundle returned by with_alias_impl
# =============================================================================
#
# Mirrors `join_helpers._BuiltJoin`: Movable-only; Optional-wrapped
# heap-owning fields so the DataFrame caller can `take_*` the inner
# values without triggering the Mojo 0.26.3 partial-move-from-struct-
# field error.
# =============================================================================
struct _BuiltAlias(Movable):
    var _plan: Optional[LogicalPlan]
    var _reg: Optional[InMemoryRegistry]
    var cnt: Int

    def __init__(
        out self,
        var plan: LogicalPlan,
        var reg: InMemoryRegistry,
        cnt: Int,
    ):
        self._plan = Optional[LogicalPlan](plan^)
        self._reg = Optional[InMemoryRegistry](reg^)
        self.cnt = cnt

    def take_plan(mut self) -> LogicalPlan:
        """Move the plan out. Leaves None. Caller owns the result."""
        return self._plan.take()

    def take_reg(mut self) -> InMemoryRegistry:
        """Move the registry out. Leaves None. Caller owns the result."""
        return self._reg.take()


# =============================================================================
# with_alias_impl -- validate the alias + build the rename Project
# =============================================================================
def with_alias_impl(
    var plan: LogicalPlan,
    var reg: InMemoryRegistry,
    cnt: Int,
    var name: String,
) raises -> _BuiltAlias:
    """Internal: rewrite `plan`'s output schema by prefixing every column
    name with `name + "."` via a Project node containing one alias
    expression per column.

    Validation:
      - `name` must be non-empty.
      - `name` must not contain `.` (dots are reserved as the namespace
        separator; nesting `with_alias("a").with_alias("b")` would
        produce ambiguous re-prefixing -- explicitly ban for now).
      - `name` must not collide with an existing alias prefix in the
        schema. The cheap detection: if every column name already
        starts with `name + "."`, this is a duplicate alias call.

    The resulting Project node is structurally:
      Project(
        exprs = [
          Alias(ColRef("c0"), "name.c0"),
          Alias(ColRef("c1"), "name.c1"),
          ...
        ],
        child = plan,
      )
    Output schema = [name.c0, name.c1, ...] with each field's arrow_type
    + nullability inherited from the child column (handled by Project's
    `_infer_expr_field` walker).
    """
    if name.byte_length() == 0:
        raise Error(
            "DataFrame.with_alias: alias name must be non-empty."
        )

    # Reject dots in the alias itself: the dotted-name resolution
    # contract says dots are the namespace separator. Allowing
    # `df.with_alias("a.b")` would produce columns like `a.b.c` whose
    # interpretation (alias=`a` with col=`b.c`, or alias=`a.b` with
    # col=`c`?) is ambiguous downstream.
    var dot_byte = UInt8(ord("."))
    # SAFETY: reads bytes [0, byte_length()) of `name`, alive for the loop.
    var name_ptr = name.unsafe_ptr()
    for i in range(name.byte_length()):
        if name_ptr[i] == dot_byte:
            raise Error(
                "DataFrame.with_alias: alias name must not contain '.' "
                "(dots are reserved as the namespace separator). "
                "Got: \"" + name + "\"."
            )

    var prefix = name + String(".")
    var ncols = plan.output_schema.num_columns()

    # Detect double-alias: every column already starts with `name.`.
    # We don't bar non-source DataFrames in general (a user may want to
    # alias a filtered/selected sub-plan), but re-aliasing with the SAME
    # prefix is almost always a bug.
    var all_already_prefixed = ncols > 0
    for i in range(ncols):
        var fname = plan.output_schema.field_name(i)
        if not _starts_with(fname, prefix):
            all_already_prefixed = False
            break
    if all_already_prefixed:
        raise Error(
            "DataFrame.with_alias: every column already has the prefix "
            "\"" + prefix + "\". Re-aliasing with the same prefix is "
            "almost certainly a bug. Use a fresh alias name."
        )

    # Build one Alias(ColRef(orig), prefix+orig) expression per column.
    var exprs = ExprArray()
    for i in range(ncols):
        var orig = plan.output_schema.field_name(i)
        var new_name = prefix + orig
        var col_ref = Expr.col_ref(orig)
        var alias_expr = Expr.alias(col_ref^, new_name)
        exprs.append(alias_expr^)

    var project = LogicalPlan.project(exprs^, plan^)
    return _BuiltAlias(project^, reg^, cnt)


# =============================================================================
# _starts_with -- prefix test helper
# =============================================================================
def _starts_with(s: String, prefix: String) -> Bool:
    """Return True iff `s` begins with `prefix`.

    String.startswith exists in stdlib but signature varies across Mojo
    versions; this is the cheap byte-by-byte fallback (mirrors
    `compiler_helpers.has_right_suffix`).
    """
    var sn = s.byte_length()
    var pn = prefix.byte_length()
    if pn > sn:
        return False
    # SAFETY: i < pn <= sn, so both reads stay inside `s` and `prefix`, which
    # outlive the loop.
    var sp = s.unsafe_ptr()
    var pp = prefix.unsafe_ptr()
    for i in range(pn):
        if sp[i] != pp[i]:
            return False
    return True
