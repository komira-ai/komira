# =============================================================================
# komira_plan_conformance/datasets.mojo -- the hand-written inputs.
# =============================================================================
#
# Each dataset is datasets/<name>.jsonl, written by hand, never by a komira
# writer: a reader or writer defect must not be able to shape both the input
# and the answer. The schema here is what every case scanning the file
# declares; test_corpus checks the file against it (member names in order,
# each value's JSON kind against the column type, `null` only where the
# column is nullable), so a hand edit to one side cannot leave the other
# behind.
#
#   bool_pairs     id, a, b: every pair of {true, false, null}, nine rows.
#   ints_nullable  id, x: x = 1, 2, null, 5.
#   groups         id, k, v: k groups 1, null and 2, with NULLs in v; the
#                  null-k group holds three rows, k = 2 only NULL values.
#   join_left      lid, lk, lv: keys 1, 2, 2, null, 3; lv NULL on lid 3.
#   join_right     rid, rk, rw: keys 2, 2, null, 4, 1.
#                  Every column of both join inputs is nullable, the ids
#                  included. §3.13 makes a padded side nullable whatever its
#                  input nullability, but LogicalPlan.join keeps the input's
#                  nullability today (query semantics, "Code that does not
#                  follow", item 12); nullable inputs keep these cases off
#                  that defect. The names differ between the two sides, so
#                  no output column is renamed (§3.14).
#   sort_rows      id, a, b, f: a = 3, null, 1, 3, null, 2, 3 (ties and two
#                  NULLs); b with one NULL; f a float64 holding 0.0 twice,
#                  -0.0 once (on a larger id than the first 0.0) and a NULL.
#                  JSON has no NaN or infinity, so neither is here.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.json_source import JsonSource
from komira_scan_source.source_variant import SourceVariant

from .plan_case import Dataset


def _schema(names: List[String], types: List[ArrowType], nullable: List[Bool]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], nullable[i]))
    return sb.build()


def bool_pairs() -> Dataset:
    return Dataset(
        "bool_pairs",
        _schema(
            [String("id"), String("a"), String("b")],
            [ArrowType.INT64, ArrowType.BOOL, ArrowType.BOOL],
            [False, True, True],
        ),
    )


def ints_nullable() -> Dataset:
    return Dataset(
        "ints_nullable",
        _schema(
            [String("id"), String("x")],
            [ArrowType.INT64, ArrowType.INT64],
            [False, True],
        ),
    )


def groups() -> Dataset:
    return Dataset(
        "groups",
        _schema(
            [String("id"), String("k"), String("v")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [False, True, True],
        ),
    )


def join_left() -> Dataset:
    return Dataset(
        "join_left",
        _schema(
            [String("lid"), String("lk"), String("lv")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [True, True, True],
        ),
    )


def join_right() -> Dataset:
    return Dataset(
        "join_right",
        _schema(
            [String("rid"), String("rk"), String("rw")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [True, True, True],
        ),
    )


def sort_rows() -> Dataset:
    return Dataset(
        "sort_rows",
        _schema(
            [String("id"), String("a"), String("b"), String("f")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64, ArrowType.FLOAT64],
            [False, True, True, True],
        ),
    )


def all_datasets() -> List[Dataset]:
    """Every dataset a case may scan; test_corpus refuses a file under
    datasets/ that is not one of these."""
    return [
        bool_pairs(), ints_nullable(), groups(), join_left(), join_right(),
        sort_rows(),
    ]


def scan(ds: Dataset) raises -> LogicalPlan:
    """A scan of the whole dataset, through the JSON Lines source."""
    var src = JsonSource(ds.path(), ds.schema.copy())
    return LogicalPlan.scan_from_source(SourceVariant(src^), ds.schema.copy())
