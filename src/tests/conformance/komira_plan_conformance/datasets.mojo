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
#   int_pairs      id, x, y: (1, 10), (NULL, 20), (3, NULL), (NULL, NULL),
#                  (5, 5): each of x and y NULL alone, both NULL, and one
#                  equal pair.
#   window_rows    id, g, v: partitions g = 1 (ids 1 to 3), 2 (ids 4, 5)
#                  and 3 (id 6, a partition of one row); v NULL on id 2,
#                  the middle row of g = 1. g is non-nullable.
#   rank_rows      id, g, o: g = 1 holds o = 10, 20, 20, 30, NULL, NULL
#                  (ids 1 to 6: a tie and two NULL order keys); g = 2 one
#                  row (id 7, o = 5); g NULL three rows (ids 8 to 10, o =
#                  7, 7, 9), a partition of their own (§9.9).
#   stat_rows      id, g, i, f, s, d: g = 1 holds i = 2, 5, 8, f = 1.0,
#                  2.5, 4.0, s = "apple", "Zebra", "app", d = 4, 4, 9 and
#                  one all-NULL row (id 4); g = 2 one row (id 5: 7, -0.5,
#                  "pear", 4); g = 3 two all-NULL rows (ids 6, 7). The
#                  values are chosen so AVG, VAR_SAMP, VAR_POP and
#                  STDDEV_SAMP are exact doubles; STDDEV_POP is not
#                  (cases_agg_stats.mojo says why).
#   avg_rows       id, g, i, f: g = 1 holds i = 2^53 + 1 and 1, f = 0.25,
#                  0.5; g = 2 holds i = 1, 2, 3, 5, f = -1.5, 2.0, 0.5,
#                  1.0 and one all-NULL row; g = 3 one all-NULL row.
#   div_pairs      id, a, b: a over b for every sign pair of 7 and 2, four
#                  zero divisors (one under a NULL a), 6 / 3, a NULL b,
#                  0 / 5 and -1 / 5 (truncating and flooring differ).
#   float_pairs    id, p, q, r: p over q gives +inf, -inf, NaN (0.0 / 0.0
#                  and 0.0 / -0.0), a NULL p, a NULL q and 1.0 / 4.0; q
#                  holds -0.0 twice; r is NULL on the 0.0 / 0.0 row only.
#                  JSON has no NaN or infinity: they are made by §5.6.
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


def int_pairs() -> Dataset:
    return Dataset(
        "int_pairs",
        _schema(
            [String("id"), String("x"), String("y")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [False, True, True],
        ),
    )


def window_rows() -> Dataset:
    return Dataset(
        "window_rows",
        _schema(
            [String("id"), String("g"), String("v")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [False, False, True],
        ),
    )


def rank_rows() -> Dataset:
    return Dataset(
        "rank_rows",
        _schema(
            [String("id"), String("g"), String("o")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [False, True, True],
        ),
    )


def stat_rows() -> Dataset:
    return Dataset(
        "stat_rows",
        _schema(
            [String("id"), String("g"), String("i"), String("f"), String("s"), String("d")],
            [
                ArrowType.INT64, ArrowType.INT64, ArrowType.INT64,
                ArrowType.FLOAT64, ArrowType.STRING, ArrowType.INT64,
            ],
            [False, False, True, True, True, True],
        ),
    )


def avg_rows() -> Dataset:
    return Dataset(
        "avg_rows",
        _schema(
            [String("id"), String("g"), String("i"), String("f")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64, ArrowType.FLOAT64],
            [False, False, True, True],
        ),
    )


def div_pairs() -> Dataset:
    return Dataset(
        "div_pairs",
        _schema(
            [String("id"), String("a"), String("b")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [False, True, True],
        ),
    )


def float_pairs() -> Dataset:
    return Dataset(
        "float_pairs",
        _schema(
            [String("id"), String("p"), String("q"), String("r")],
            [ArrowType.INT64, ArrowType.FLOAT64, ArrowType.FLOAT64, ArrowType.FLOAT64],
            [False, True, True, True],
        ),
    )


def all_datasets() -> List[Dataset]:
    """Every dataset a case may scan; test_corpus refuses a file under
    datasets/ that is not one of these."""
    return [
        bool_pairs(), ints_nullable(), groups(), join_left(), join_right(),
        sort_rows(), int_pairs(), window_rows(), rank_rows(), stat_rows(),
        avg_rows(), div_pairs(), float_pairs(),
    ]


def scan(ds: Dataset) raises -> LogicalPlan:
    """A scan of the whole dataset, through the JSON Lines source."""
    var src = JsonSource(ds.path(), ds.schema.copy())
    return LogicalPlan.scan_from_source(SourceVariant(src^), ds.schema.copy())
