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


def all_datasets() -> List[Dataset]:
    """Every dataset a case may scan; test_corpus refuses a file under
    datasets/ that is not one of these."""
    return [bool_pairs(), ints_nullable(), groups()]


def scan(ds: Dataset) raises -> LogicalPlan:
    """A scan of the whole dataset, through the JSON Lines source."""
    var src = JsonSource(ds.path(), ds.schema.copy())
    return LogicalPlan.scan_from_source(SourceVariant(src^), ds.schema.copy())
