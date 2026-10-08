# =============================================================================
# komira_plan_conformance/cases_scan_jsonl.mojo -- shard scan_jsonl.
# =============================================================================
#
# The SCAN NODE itself, over hand-written JSON Lines. Every other shard
# reaches its data through `datasets.scan`, a whole-file scan whose declared
# schema is the file's; that helper is not used here. Each case builds its
# scan with `LogicalPlan.scan_from_source` over a `JsonSource` (the plan's
# `komira.json` binding) and states its own declared schema, projection and
# pushed-down filter, so what is under test is what the scan node does with
# them: the scan's output schema, which columns and rows come out, and how
# NULL and '' flow through.
#
# Two inputs, the same four rows (datasets.mojo):
#   scan_rows        {"id", "x", "s"} in that order:
#                    (1, 10, "a"), (2, null, ""), (3, 30, null), (4, -5, "d")
#   scan_key_order   the same rows, each line's members in another order
#                    (id x s, s id x, x s id, x id s)
#
# Reading a JSON `null` as NULL and `""` as '' is what §7.13 proposes; §7.13
# is UNDECIDED as a whole, and every shard of this corpus already relies on
# that reading (plan_case.mojo). The CSV empty-field rule, the part §7.13
# leaves open for text readers, does not arise in JSON. Binding a member by
# its name, whatever its position, rests on JSON itself: RFC 8259 §4 makes an
# object an unordered collection of name/value pairs. The query-semantics
# document has no item for a scan node; the derivations cite the items the
# rows rest on (§1.2, §4.8, §7.12, §7.13, §8's nullability rule).
#
# No root sorts, so every case compares its rows as a multiset (§4.8).
#
# Not here, and why:
#   - Nested NULLs (a null inside an object or array value): nested types
#     are outside the document's scope.
#   - A missing key: no item says whether an absent member reads as NULL
#     or is refused; §7.13 speaks only of `null` and `""`.
#   - Type coercion between the file and the declared schema (a JSON 1 in a
#     float64 column, 1.0 in an int64 column, an int64 declared int32): the
#     document settles no reader coercion; §6's casts are CAST expressions,
#     not reads.
#   - A column declared non-nullable over a file that holds a null: §8 calls
#     the declaration a defect but no item says whether the reader refuses
#     the file or the plan; a refusal case waits for an executor.
#   - An extra member the declared schema does not name: no item says
#     whether it is ignored or refused.
#   - A projection naming a column the declared schema lacks: not a case.
#     `scan_from_source` drops the name without raising and the plan wire's
#     value gate refuses the plan, so it cannot pass test_corpus.
#
# The defect each case would catch once it executes:
#   explicit_null_and_empty   a JSON null read as 0 or ""; "" read as NULL
#   key_order                 members bound by position (line 2 would give
#                             id = "", x = 2, s = NULL)
#   projection_reorder        a projection ignored, or output in the file's
#                             column order rather than the projection's
#   pushed_filter_drops_x
#                             a pushed filter ignored, a NULL predicate kept
#                             (id 2), or the filter resolved after the
#                             projection has dropped x
#   pushed_filter_empty_string
#                             '' and NULL merged (id 3 kept, or id 2 lost)
#   declared_nullable_over_non_null
#                             the scan reporting the file's nullability (id
#                             non-nullable) rather than the declared schema's
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import BIN_EQ, BIN_GT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.json_source import JsonSource
from komira_scan_source.source_variant import SourceVariant

from .plan_case import Case
from .datasets import scan_key_order, scan_rows, scan_rows_schema

comptime SHARD = "scan_jsonl"


def _scan(
    path: String,
    var declared: Schema,
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) raises -> LogicalPlan:
    """A scan node over the JSON Lines file at `path`, declaring `declared`,
    with an optional projection and pushed-down filter."""
    var src = JsonSource(path, declared.copy())
    return LogicalPlan.scan_from_source(
        SourceVariant(src^), declared^, projection^, filter^
    )


def _explicit_null_and_empty() raises -> LogicalPlan:
    return _scan(scan_rows().path(), scan_rows_schema())


def _key_order() raises -> LogicalPlan:
    return _scan(scan_key_order().path(), scan_rows_schema())


def _projection_reorder() raises -> LogicalPlan:
    var proj: List[String] = [String("s"), String("id")]
    return _scan(scan_rows().path(), scan_rows_schema(), Optional(proj^))


def _pushed_filter_drops_x() raises -> LogicalPlan:
    var proj: List[String] = [String("id")]
    var pred = Expr.binary(
        BIN_GT, Expr.col_ref("x"), Expr.literal(ScalarValue.from_int64(Int64(0)))
    )
    return _scan(
        scan_rows().path(), scan_rows_schema(), Optional(proj^), Optional(pred^)
    )


def _pushed_filter_empty_string() raises -> LogicalPlan:
    var proj: List[String] = [String("id"), String("s")]
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref("s"), Expr.literal(ScalarValue.from_string(String("")))
    )
    return _scan(
        scan_rows().path(), scan_rows_schema(), Optional(proj^), Optional(pred^)
    )


def _declared_nullable_over_non_null() raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("x", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return _scan(scan_rows().path(), sb.build())


def cases() -> List[Case]:
    """The shard's cases. Without an ORDER BY a result's row order is not
    defined (§4.8), so every case compares its rows as a multiset."""
    return [
        Case.hand("explicit_null_and_empty", SHARD, _explicit_null_and_empty, CanonPolicy.unordered()),
        Case.hand("key_order", SHARD, _key_order, CanonPolicy.unordered()),
        Case.hand("projection_reorder", SHARD, _projection_reorder, CanonPolicy.unordered()),
        Case.hand(
            "pushed_filter_drops_x", SHARD, _pushed_filter_drops_x,
            CanonPolicy.unordered(),
        ),
        Case.hand(
            "pushed_filter_empty_string", SHARD, _pushed_filter_empty_string,
            CanonPolicy.unordered(),
        ),
        Case.hand(
            "declared_nullable_over_non_null", SHARD, _declared_nullable_over_non_null,
            CanonPolicy.unordered(),
        ),
    ]
