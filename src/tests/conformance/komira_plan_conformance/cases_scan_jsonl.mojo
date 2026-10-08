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
# The inputs (datasets.mojo):
#   scan_rows        {"id", "x", "s"} in that order:
#                    (1, 10, "a"), (2, null, ""), (3, 30, null), (4, -5, "d")
#   scan_key_order   the same rows, each line's members in another order
#                    (id x s, s id x, x s id, x id s)
#   scan_sparse      (1, 10, s missing), (2, x missing, "b", note "extra"),
#                    (3, 30, "c", note 7, out of order)
#   scan_numbers     id, f float64: 1 (a JSON integer), 2.5, null, -3
#
# The items, in query semantics section 13 (scans) and §7.17:
#   §7.17   JSON `null` reads as NULL, JSON `""` as ''.
#   §13.1   a projection outputs its columns in the projection's order.
#   §13.3   a filter carried by the scan is a Filter above it, on the source
#           columns before the projection; a NULL predicate drops the row.
#           Pushdown is only an optimization: komira.json, like komira.avro,
#           declines every predicate (JsonSource.supports_filter_pushdown
#           returns False), so the executor must apply the scan's filter
#           itself, and these cases are what show it does.
#   §13.6   a JSON integer reads into INT64, and any JSON number (an integer
#           included) into FLOAT64.
#   §13.8   members bind by name in any order; a missing member is NULL in a
#           nullable column; an undeclared member is ignored.
#   §13.10  a column declared nullable over a file with no NULL is sound.
#
# No root sorts, so every case compares its rows as a multiset (§4.8).
#
# Not here, and why:
#   - Nested NULLs (a null inside an object or array value): nested types
#     are outside the document's scope.
#   - A JSON value of another type than its column (§13.7) and a repeated
#     key (§13.9): both UNDECIDED.
#   - A missing member, or a null, in a non-nullable column: §13.8 and
#     §13.10 make it a reader error, but nothing fixes the error's code or
#     kind, which an .err expectation must state; it waits for an executor.
#   - A projection naming a column the schema lacks: §13.2 refuses it, but
#     scan_from_source drops the name silently ("Code that does not follow",
#     item 15); only the wire's value gate refuses it, so such a case cannot
#     pass test_corpus.
#   - The CSV empty field (§7.13, UNDECIDED): not JSON.
#
# The defect each case would catch once it executes:
#   explicit_null_and_empty   a JSON null read as 0 or ""; "" read as NULL
#   key_order                 members bound by position (line 2 would give
#                             id = "", x = 2, s = NULL)
#   missing_and_extra_members a missing member refused or read as 0 / "";
#                             an undeclared member refused, or bound to a
#                             column by position
#   projection_reorder        a projection ignored, or output in the file's
#                             column order rather than the projection's
#   pushed_filter_drops_x     a pushed filter ignored (the kind declines it),
#                             a NULL predicate kept (id 2), or the filter
#                             resolved after the projection has dropped x
#   pushed_filter_empty_string
#                             '' and NULL merged (id 3 kept, or id 2 lost)
#   json_integer_into_float64 a JSON integer refused in a FLOAT64 column, or
#                             read as something other than its value
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
from .datasets import (
    scan_key_order,
    scan_numbers,
    scan_rows,
    scan_rows_schema,
    scan_sparse,
)

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


def _missing_and_extra_members() raises -> LogicalPlan:
    return _scan(scan_sparse().path(), scan_rows_schema())


def _json_integer_into_float64() raises -> LogicalPlan:
    var ds = scan_numbers()
    return _scan(ds.path(), ds.schema.copy())


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
        Case.hand(
            "missing_and_extra_members", SHARD, _missing_and_extra_members,
            CanonPolicy.unordered(),
        ),
        Case.hand(
            "json_integer_into_float64", SHARD, _json_integer_into_float64,
            CanonPolicy.unordered(),
        ),
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
