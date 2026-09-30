# =============================================================================
# `_infer_agg_field` — the PLAN layer's declared output Field for `min(t)` /
# `max(t)` where `t` is TIMESTAMP_US **tz=UTC**.
# =============================================================================
#
# ★ THE DEFECT, AND IT IS THE SECOND HALF OF ONE MISTAKE. The engine's
#   aggregate descriptor build (`agg_node_exec._agg_out_field` /
#   `_agg_key_out_field`) must keep the zone — that is the schema the drain
#   publishes. This is the OTHER site, one layer up, and it can drop the zone
#   on the line immediately after it states the rule that forbids doing so:
#
#       # For MIN, MAX, FIRST, LAST, ANY_VALUE: infer type from the child
#       # expression (NO promotion).
#       if agg.child:
#           var child_field = _infer_expr_field(agg.child.value(), schema)
#           return Field(output_name, child_field.arrow_type, True)
#                                     ^^^^^^^^^^^^^^^^^^^^^^
#
#   It reads the child FIELD — which carries the zone — and then passes only
#   its `.arrow_type` to the bare 3-arg ctor. `timestamp_us_utc` IS NOT ITS OWN
#   `ArrowType`: a UTC timestamp and a naive one are BOTH
#   `ArrowType.TIMESTAMP_US`, discriminated only by `Field._tz`. So "infer the
#   type from the child" is implemented as "infer the DISCRIMINATOR from the
#   child", and the parameters are silently defaulted away.
#
# ⚠ WHY THIS SITE MATTERS SEPARATELY FROM THE ENGINE'S. `_infer_agg_field`'s
#   own header calls it "the RUNTIME AUTHORITY on aggregate output types", and
#   `LogicalPlan.aggregate` stamps its answer into the node's `output_schema`.
#   That schema is what a consumer reads BEFORE any data moves — plan display,
#   schema propagation up through a parent node, and anything that answers
#   "what will this query return" without executing it. A plan that declares a
#   naive timestamp and an executor that now delivers a tz-aware one is a
#   DISAGREEMENT between two authorities; fixing the engine half alone creates
#   it.
#
# ⚠⚠ AND IT IS A WRONG ANSWER, NOT A LABEL. Arrow's `Timestamp(unit, tz=None)`
#   and `Timestamp(unit, tz="UTC")` are DIFFERENT types in `Schema.fbs` and
#   different C Data Interface format strings (`tsu:` vs `tsu:UTC`). A consumer
#   reading `tsu:` treats the ticks as a local wall clock with NO instant
#   attached, so every row means a different moment depending on the reader's
#   session zone.
#
# ★★ AND THERE IS A SECOND, LARGER SITE IN THE SAME FILE-PAIR, WHICH §5 COVERS.
#   `expr_walk.PlanColRefFields.col_ref_field` is — by its own header —
#   "THE PLAN-BUILD-TIME policy" behind `walk_expr_field`, "★ THE ONLY
#   OUTPUT-FIELD INFERENCE IN THE TREE", through which *EVERY* plan node's
#   `output_schema` is synthesized. It resolves a `col_ref` by HAND-COPYING
#   slots off the source schema:
#
#       name ✓  arrow_type ✓  nullable ✓  decimal_precision ✓
#       decimal_scale ✓  nested children ✓        _tz ✗
#
#   Its SIBLING policy, twenty lines above, uses `schema.field_at_unchecked(i)`
#   and therefore preserves every slot. Two policies, one question, and the
#   INCOMPLETE one is the one every plan node uses. ⇒ a plain `SELECT t` over a
#   tz-aware column DECLARES a naive timestamp, even though the executor
#   delivers a tz-aware one (an end-to-end check that reads the EXECUTED
#   schema, not the declared one, cannot see this).
#
#   ⚠ THE FIX HERE IS DELIBERATELY NOT "SWITCH TO `field_at_unchecked`". That
#   policy's header states why — `field_at_unchecked` also restores the
#   schema's STORED `dtype` slot, which `SchemaBuilder` fills from whatever
#   Field the caller handed it and which can legitimately DISAGREE with
#   `arrow_type`; changing which `dtype` every plan node's output schema
#   carries is a blast radius far beyond a timezone. Adding the `_tz` slot to
#   the hand-copy is the subset that touches nothing else.
#
# ============================ THE ORACLE =====================================
#
# NOT this engine. DuckDB v1.5.3:
#
#   SELECT typeof(min(t)), typeof(max(t)) FROM (
#     SELECT '2030-01-01 01:30:15.123456+00'::TIMESTAMPTZ AS t);
#   --  TIMESTAMP WITH TIME ZONE | TIMESTAMP WITH TIME ZONE
#
#   -- and a TIMESTAMPTZ group key stays TIMESTAMPTZ:
#   SELECT typeof(t) FROM (SELECT '2030-01-01 01:30:15.123456+00'::TIMESTAMPTZ
#     AS t) GROUP BY t;
#   --  TIMESTAMP WITH TIME ZONE
#
# min/max PICK an existing value, so the output type IS the input's; a group
# key is passed through, so its type is unchanged.
#
# ============================ REVERT-AND-RED =================================
#
# Each mutation below was run against this file:
#
#   M1  revert the MIN/MAX/FIRST/LAST/ANY_VALUE branch to
#       `Field(output_name, child_field.arrow_type, True)`
#         -> 9/11. RED: §2 (tz pick) + §6 (decimal pick). §5 stays GREEN.
#   M2  drop the `_tz` copy from `PlanColRefFields.col_ref_field`
#         -> 9/11. RED: §5 **AND §2**. §6 (decimal) stays GREEN.
#   M3  mint the zone from the TYPE (`out._tz = "UTC"` whenever
#       `at.is_timestamp()`) instead of copying it from the child FIELD
#         -> 10/11. RED: §3 alone — the over-fix guard.
#
# ⛔ M2 shows §5 is NOT independent of §2 — see §5's own header. The two
# sites are a DIRECTED CHAIN and the `col_ref` hand-copy is upstream.
# §1 and §3 stay GREEN under that revert BY CONSTRUCTION: §1 is the pre-fix measurement
# the fix rests on (the plan's Schema CAN carry a zone) and §3 is the over-fix
# guard (a NAIVE column must stay naive — what a fix keyed on the ArrowType
# instead of the child Field gets wrong in the mirror direction). §4 is also
# green pre-fix: COUNT's declared INT64 must not acquire a zone.
#
# Encapsulation: NO UnsafePointer / wildcard origins /
#   unsafe_from_address / take_pointee in THIS test.
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.plan.expr import Expr
from komira_core.plan.agg_expr import (
    AggExpr, AGG_COUNT, AGG_MAX, AGG_MEAN, AGG_MIN,
)
from komira_core.plan.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan, SOURCE_PARQUET,
)

comptime _TZ = "UTC"


def _schema(tz: String) raises -> Schema:
    """`k` INT64 (a group key), `t` TIMESTAMP_US with the given zone."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(
        Field.timestamp(String("t"), ArrowType.TIMESTAMP_US, tz, False)
    )
    return sb.build()


def _agg_plan(func: UInt8, col: Optional[String], tz: String) raises -> LogicalPlan:
    """`SELECT k, <func>(<col> | *) AS r FROM t GROUP BY k`, built through
    `LogicalPlan.aggregate` so the node's `output_schema` is the one
    `_infer_agg_field` produced."""
    var child = LogicalPlan.scan(
        String("dummy.parquet"), SOURCE_PARQUET, _schema(tz)
    )
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("k")))
    var aggs = AggExprArray()
    var child_expr: Optional[Expr] = None
    if col:
        child_expr = Optional[Expr](Expr.col_ref(col.value()))
    aggs.append(AggExpr(func, child_expr^, Optional[String](String("r"))))
    return LogicalPlan.aggregate(keys^, aggs^, child^)


def _tz_of(imm s: Schema, name: String) raises -> String:
    for i in range(s.num_columns()):
        if String(s.field_at_unchecked(i).name) == name:
            return s.field_tz(i)
    raise Error("no output column named '" + name + "'")


def _at_of(imm s: Schema, name: String) raises -> ArrowType:
    for i in range(s.num_columns()):
        if String(s.field_at_unchecked(i).name) == name:
            return s.field_at_unchecked(i).arrow_type
    raise Error("no output column named '" + name + "'")


def _ps_of(imm s: Schema, name: String) raises -> String:
    """`"(p,s)"` for the named output column — the decimal PARAMETERS, which
    like `_tz` live on the Field and NOT in the `ArrowType` discriminator."""
    for i in range(s.num_columns()):
        if String(s.field_at_unchecked(i).name) == name:
            return (
                "("
                + String(s.field_decimal_precision(i))
                + ","
                + String(s.field_decimal_scale(i))
                + ")"
            )
    raise Error("no output column named '" + name + "'")


def _dec_schema() raises -> Schema:
    """`k` INT64 (a group key), `d` DECIMAL128(12, 2)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field.decimal128(String("d"), 12, 2, False))
    return sb.build()


def _dec_agg_plan(func: UInt8, col: String) raises -> LogicalPlan:
    """`SELECT k, <func>(d) AS r FROM t GROUP BY k` over `_dec_schema()`."""
    var child = LogicalPlan.scan(
        String("dummy.parquet"), SOURCE_PARQUET, _dec_schema()
    )
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("k")))
    var aggs = AggExprArray()
    var child_expr: Optional[Expr] = Optional[Expr](Expr.col_ref(col))
    aggs.append(AggExpr(func, child_expr^, Optional[String](String("r"))))
    return LogicalPlan.aggregate(keys^, aggs^, child^)


# =============================================================================
# §1 — ⭐ THE SUBSTRATE PROOF. GREEN ON THE UNFIXED TREE.
# =============================================================================


def test_CONTROL_the_plans_own_Schema_carries_a_zone() raises:
    """★ Pre-fix measurement, on BOTH ends of the plan. The SCAN's output
    schema round-trips the zone, so §2's red is about `_infer_agg_field` and
    not about a Schema that cannot represent the answer."""
    var scan = LogicalPlan.scan(
        String("dummy.parquet"), SOURCE_PARQUET, _schema(String(_TZ))
    )
    assert_equal(
        _tz_of(scan.output_schema, String("t")), String(_TZ),
        "the SCAN node's output schema carries the zone — the slot exists and"
        " the plan layer fills it at the leaf",
    )


# =============================================================================
# §2 — THE DEFECT. RED on the unfixed tree.
# =============================================================================


def test_min_and_max_over_a_UTC_timestamp_DECLARE_the_zone() raises:
    """★ THE DEFECT. Pre-fix the AGGREGATE node declares `r` as a NAIVE
    timestamp while its own rule says the output type IS the child's."""
    var p_min = _agg_plan(AGG_MIN, Optional[String](String("t")), String(_TZ))
    assert_equal(
        _tz_of(p_min.output_schema, String("r")), String(_TZ),
        "`min(t)` PICKS an existing value, so the DECLARED output field must"
        " carry the child's zone — DuckDB's typeof(min(<TIMESTAMPTZ>)) is"
        " TIMESTAMP WITH TIME ZONE",
    )
    var p_max = _agg_plan(AGG_MAX, Optional[String](String("t")), String(_TZ))
    assert_equal(
        _tz_of(p_max.output_schema, String("r")), String(_TZ),
        "and `max(t)` for the same reason",
    )


def test_the_GROUP_KEY_column_still_declares_its_own_type() raises:
    """⚠ THE NON-AGG HALF OF THE SAME SCHEMA, asserted so a fix to the agg
    branch cannot be mistaken for a fix to the whole node. The key `k` is an
    INT64 and must stay one, with no zone."""
    var p = _agg_plan(AGG_MIN, Optional[String](String("t")), String(_TZ))
    assert_equal(
        Int(_at_of(p.output_schema, String("k")).type_id),
        Int(ArrowType.INT64.type_id),
        "the group key passes through as INT64",
    )
    assert_equal(
        _tz_of(p.output_schema, String("k")), String(""),
        "and a non-temporal key acquires no zone",
    )


# =============================================================================
# §3 / §4 — THE OVER-FIX GUARDS. GREEN ON THE UNFIXED TREE (both assert
# TODAY'S answer), and they are what fails if the fix stamps a zone from the
# TYPE rather than from the child FIELD.
# =============================================================================


def test_a_NAIVE_timestamp_is_DECLARED_naive() raises:
    """⛔ THE MIRROR-IMAGE WRONG ANSWER. `timestamp_us` and `timestamp_us_utc`
    are the SAME ArrowType; a fix keyed on `at.is_timestamp()` alone would
    declare a naive column UTC."""
    var p = _agg_plan(AGG_MIN, Optional[String](String("t")), String(""))
    assert_equal(
        _tz_of(p.output_schema, String("r")), String(""),
        "a naive input is declared naive — the zone comes from the CHILD"
        " FIELD, never minted from the ArrowType",
    )
    assert_equal(
        Int(_at_of(p.output_schema, String("r")).type_id),
        Int(ArrowType.TIMESTAMP_US.type_id),
        "and the unit is still carried",
    )


def test_COUNT_declares_INT64_with_no_zone() raises:
    """⛔ COUNT returns INT64 BEFORE the MIN/MAX branch is reached, whatever
    its input was. A fix that stamped the child's zone unconditionally — rather
    than inside the pick branch — would hand back an INT64 carrying 'UTC',
    which `Field.timestamp` would REFUSE and which no reader expects."""
    var p = _agg_plan(AGG_COUNT, Optional[String](String("t")), String(_TZ))
    assert_equal(
        Int(_at_of(p.output_schema, String("r")).type_id),
        Int(ArrowType.INT64.type_id),
        "count over a tz-aware timestamp is still an INT64",
    )
    assert_equal(
        _tz_of(p.output_schema, String("r")), String(""),
        "and it carries no zone",
    )


# =============================================================================
# §5 — THE PLAN-WIDE COL_REF SITE. RED on the unfixed tree.
#
# ⭐⭐ §5 AND §2 ARE **NOT** INDEPENDENT — THEY ARE A CHAIN, AND §5's SITE IS
#   THE UPSTREAM LINK. Mutation M2 (delete the
#   `_tz` copy from `col_ref_field` and leave `_pick_out_field` intact) reds
#   **BOTH** §5 and §2. The reason is that `_infer_agg_field` obtains its
#   `child_field` from `_infer_expr_field`, which resolves a `col_ref` through
#   `walk_expr_field[PlanColRefFields]` — i.e. through the very hand-copy §5
#   is about. So `_pick_out_field` can only carry a zone that
#   `col_ref_field` supplied: **neither fix is sufficient alone and both are
#   necessary.** (M1, which reverts only `_pick_out_field`, reds §2 and §6 and
#   leaves §5 GREEN — the chain is directional.)
#
# ⭐ AND THE DECIMAL HALF HAS ONLY *ONE* BROKEN LINK, WHICH IS WHY §7 IS THE
#   CONTROL IT IS. Under M2 the decimal arm §6 stays GREEN, because
#   `col_ref_field` ALREADY copied `decimal_precision` / `decimal_scale`. One
#   omitted slot in one shared hand-copy is the whole difference between a
#   one-fix family and a two-fix family.
# =============================================================================


def test_a_tz_aware_GROUP_KEY_is_DECLARED_tz_aware() raises:
    """★ THE SECOND DEFECT, and the one with the wider blast radius. This
    exercises `walk_expr_field[PlanColRefFields]` — the inference EVERY plan
    node's `output_schema` goes through — rather than the aggregate's own
    output rule."""
    var child = LogicalPlan.scan(
        String("dummy.parquet"), SOURCE_PARQUET, _schema(String(_TZ))
    )
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("t")))
    var aggs = AggExprArray()
    var none_child: Optional[Expr] = None
    aggs.append(
        AggExpr(AGG_COUNT, none_child^, Optional[String](String("n")))
    )
    var p = LogicalPlan.aggregate(keys^, aggs^, child^)
    assert_equal(
        _tz_of(p.output_schema, String("t")), String(_TZ),
        "a `col_ref` group key is PASSED THROUGH, so its declared output field"
        " must carry the source zone — `col_ref_field` hand-copies name /"
        " arrow_type / nullable / decimal (p,s) / children and omitted `_tz`",
    )
    assert_equal(
        Int(_at_of(p.output_schema, String("t")).type_id),
        Int(ArrowType.TIMESTAMP_US.type_id),
        "and its unit is carried, not flattened",
    )


def test_a_NAIVE_col_ref_key_is_DECLARED_naive() raises:
    """⛔ THE OVER-FIX GUARD FOR §5, and GREEN ON THE UNFIXED TREE. Copying
    the slot is right; defaulting it to a zone is the mirror-image wrong
    answer."""
    var child = LogicalPlan.scan(
        String("dummy.parquet"), SOURCE_PARQUET, _schema(String(""))
    )
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("t")))
    var aggs = AggExprArray()
    var none_child: Optional[Expr] = None
    aggs.append(
        AggExpr(AGG_COUNT, none_child^, Optional[String](String("n")))
    )
    var p = LogicalPlan.aggregate(keys^, aggs^, child^)
    assert_equal(
        _tz_of(p.output_schema, String("t")), String(""),
        "a naive key is declared naive",
    )


# =============================================================================
# §6 / §7 / §8 — THE SAME MISTAKE, THE OTHER PARAMETERISED FAMILY. Decimal's
# `(precision, scale)` live on the `Field` exactly as `_tz` does, and the SAME
# bare 3-arg ctor on the SAME line drops them. Asserted separately because a
# fix that special-cases `is_timestamp()` clears §2 and leaves these RED — the
# defect is the ctor call, not the temporal family.
#
# ⚠⚠ AND THE DECIMAL LOSS IS STRICTLY WORSE THAN THE TIMEZONE ONE: a
# `DECIMAL128` Field with `(0, 0)` is not merely under-specified, it is an
# ILLEGAL Arrow decimal. `Field.decimal128` itself REFUSES `precision < 1`
# ("precision must be in [1, 38]"), and the C Data Interface format string for
# it is `d:0,0` — which arrow-cpp, pyarrow and arrow-rs all reject on import.
# So the plan declares a type its own constructor would not have built.
#
# =========================== THE ORACLE ======================================
#
# DuckDB v1.5.3 over a `DECIMAL(12,2)` column:
#
#   min -> DECIMAL(12,2)   max -> DECIMAL(12,2)   first -> DECIMAL(12,2)
#   last -> DECIMAL(12,2)  any_value -> DECIMAL(12,2)
#   GROUP BY d -> DECIMAL(12,2)
#   count -> BIGINT        avg -> DOUBLE          sum -> DECIMAL(38,2)
#
# The five PICKS return the input type unchanged — the same rule §2 asserts
# for the zone, which is why one fix serves both.
#
# ⛔ `sum` IS DELIBERATELY NOT ASSERTED HERE, AND NOT BECAUSE IT IS CORRECT.
# It is a THIRD wrong answer at a FOURTH site: the SUM branch twelve lines
# above returns `Field(output_name, ct, True)` for a non-promoted type, so
# `sum(d)` is declared `DECIMAL128(0,0)` too. Its right answer needs a
# PROMOTION RULE (measured above: precision -> 38, scale preserved; and
# `DECIMAL(38,2)` stays `DECIMAL(38,2)`), not a parameter copy — and this
# engine's `agg_node_exec._agg_output_arrow` has NO DECIMAL128 result arm at
# all, so declaring `DECIMAL(38,2)` here would create a plan/engine
# DISAGREEMENT where today there is a shared (wrong) answer. Stated as a
# residual on purpose; fixed WITH the engine arm, not before it.
# =============================================================================


def test_min_and_max_over_a_DECIMAL_keep_precision_and_scale() raises:
    """★ THE DEFECT, decimal half. RED on the unfixed tree: `(0,0)`."""
    var p_min = _dec_agg_plan(AGG_MIN, String("d"))
    assert_equal(
        _ps_of(p_min.output_schema, String("r")), String("(12,2)"),
        "`min(d)` PICKS an existing value, so the declared output field keeps"
        " the child's (precision, scale) — DuckDB v1.5.3"
        " typeof(min(<DECIMAL(12,2)>)) is DECIMAL(12,2)",
    )
    assert_equal(
        Int(_at_of(p_min.output_schema, String("r")).type_id),
        Int(ArrowType.DECIMAL128.type_id),
        "and it is still a DECIMAL128 — the ArrowType was never the wrong"
        " part",
    )
    var p_max = _dec_agg_plan(AGG_MAX, String("d"))
    assert_equal(
        _ps_of(p_max.output_schema, String("r")), String("(12,2)"),
        "and `max(d)` for the same reason",
    )


def test_CONTROL_a_DECIMAL_group_key_already_keeps_its_parameters() raises:
    """⭐ GREEN ON THE UNFIXED TREE, and it is the measurement that splits the
    two sites. A `col_ref` group key resolves through
    `PlanColRefFields.col_ref_field`, whose hand-copy ALREADY carries
    `decimal_precision` / `decimal_scale` — and omits `_tz`. So the decimal
    parameters survive the path where the zone does not, which is why §5 is
    red and this is green from the same function."""
    var child = LogicalPlan.scan(
        String("dummy.parquet"), SOURCE_PARQUET, _dec_schema()
    )
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("d")))
    var aggs = AggExprArray()
    var none_child: Optional[Expr] = None
    aggs.append(
        AggExpr(AGG_COUNT, none_child^, Optional[String](String("n")))
    )
    var p = LogicalPlan.aggregate(keys^, aggs^, child^)
    assert_equal(
        _ps_of(p.output_schema, String("d")), String("(12,2)"),
        "a DECIMAL col_ref key keeps (p,s) on the UNFIXED tree — the hand-copy"
        " carries the decimal slots already",
    )


def test_COUNT_over_a_DECIMAL_carries_no_decimal_parameters() raises:
    """⛔ THE OVER-FIX GUARD, decimal half. GREEN ON THE UNFIXED TREE. A fix
    that copied the child's parameters BEFORE the COUNT arm — or outside the
    pick branch — would hand back an INT64 stamped `(12,2)`, a Field
    `Field.decimal128` would never have produced and which the C-Data export
    renders as a plain `l`, silently discarding the claim."""
    var p = _dec_agg_plan(AGG_COUNT, String("d"))
    assert_equal(
        Int(_at_of(p.output_schema, String("r")).type_id),
        Int(ArrowType.INT64.type_id),
        "count over a decimal is an INT64 — DuckDB v1.5.3 typeof(count(d)) is"
        " BIGINT",
    )
    assert_equal(
        _ps_of(p.output_schema, String("r")), String("(0,0)"),
        "and it carries NO decimal parameters",
    )


def test_MEAN_over_a_DECIMAL_is_FLOAT64_with_no_parameters() raises:
    """⛔ THE SECOND OVER-FIX GUARD, and the one that pins a REAL boundary
    rather than a hypothetical: `avg` does not pick, it computes, so its
    output type is NOT its input's. MEASURED v1.5.3:
    typeof(avg(<DECIMAL(12,2)>)) is DOUBLE. GREEN on the unfixed tree."""
    var p = _dec_agg_plan(AGG_MEAN, String("d"))
    assert_equal(
        Int(_at_of(p.output_schema, String("r")).type_id),
        Int(ArrowType.FLOAT64.type_id),
        "avg over a decimal is a FLOAT64, not a decimal",
    )
    assert_equal(
        _ps_of(p.output_schema, String("r")), String("(0,0)"),
        "and it carries no decimal parameters",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
