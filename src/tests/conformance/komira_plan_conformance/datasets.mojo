# =============================================================================
# komira_plan_conformance/datasets.mojo -- the scan inputs and their schemas.
# =============================================================================
#
# Each dataset is datasets/<name>.jsonl, written by hand (or, for weather,
# by upstream Apache Avro), never by a komira writer: a reader or writer
# defect must not be able to shape both the input and the answer. The schema
# here is what every case scanning the file declares; test_corpus checks the
# file against it (member names in order, or in any order for a dataset with
# `any_member_order`, with the missing and extra members a sparse dataset
# allows; each value's JSON kind against the column type, an int32 value in
# range; `null` only where the column is nullable), so a hand
# edit to one side cannot leave the other behind.
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
#   set_left       id, k, s: (1, "a") twice, (NULL, "a") twice, (NULL,
#                  NULL) twice, (2, NULL), (2, "b"), and (4, "e" followed
#                  by U+0301, the decomposed e-acute: bytes 65 CC 81).
#   set_right      id, k, s: (1, "a") and (NULL, NULL), both also in
#                  set_left; (3, U+65E5, 3 bytes); (2, "B"); (4, U+00E9, the
#                  precomposed e-acute: bytes C3 A9); (5, U+1F600, 4 bytes).
#                  The two sides have identical column names and types, as
#                  §11.1 and §11.4 require of set-operation inputs.
#   str_rows       id, s, t: s = "abc", "h" U+00E9 "llo", U+65E5 U+672C,
#                  "a" U+1F600 "b", "", NULL, "Stra" U+00DF "e", NULL,
#                  U+1F600 (1-, 2-, 3- and 4-byte characters, the empty
#                  string and NULL); t = "x", NULL, "", "-", NULL, "y",
#                  U+00C4 U+00D6, NULL, U+FF21 (fullwidth A: EF BC A1,
#                  below U+1F600's F0 by bytes, above its UTF-16 lead
#                  surrogate D83D).
#   scan_rows      id, x, s: (1, 10, "a"), (2, null, ""), (3, 30, null),
#                  (4, -5, "d"): an explicit null in an integer and in a
#                  string column, and "" beside null. Scanned only by
#                  scan_jsonl, which builds its scans itself.
#   scan_key_order the same four rows as scan_rows, each line's members in
#                  a different order (id x s, s id x, x s id, x id s), with
#                  `any_member_order`: every column exactly once per line,
#                  in any order.
#   scan_sparse    id, x, s, with `any_member_order`, `missing_ok` and the
#                  extra member `note`: {"id": 1, "x": 10} (s missing),
#                  {"id": 2, "s": "b", "note": "extra"} (x missing, an
#                  undeclared member), {"s": "c", "note": 7, "id": 3, "x":
#                  30} (every column, out of order, and `note` again).
#   scan_numbers   id, f (float64, nullable): f = 1 (a JSON integer), 2.5,
#                  null, -3 (a negative JSON integer).
#   frame_rows     id, g, v, w, u: g = 1 ids 1 to 5, v = 3, NULL, 5, 1, 4;
#                  g = 2 ids 6, 7, v NULL on both (a partition of only
#                  NULLs); g = 3 id 8, v = 9 (a partition of one row). w =
#                  10 * id, non-nullable; u = id, declared nullable but
#                  holding no NULL, so a NULL FIRST_VALUE or LAST_VALUE of u
#                  can only come from an empty frame. id is a total order
#                  key within each g, so a ROWS frame has one answer.
#   asof_left      lid, lg, lt: lid non-nullable; lg the equality key, lt
#                  the ordering value. lg = 1 rows with lt = 20 (equal to a
#                  right rt), 24, 25 (equidistant from rt 20 and 30), 5
#                  (below every rg = 1 rt), 35 (above every rg = 1 rt); lg =
#                  2 with lt 7;
#                  a NULL lg (lt 15); a NULL lt (lg 1); lg = 3 (no right
#                  group).
#   asof_right     rid, rg, rt, rv: rg = 1 holds rt = 10, 20, 30 and one
#                  NULL rt; rg = 2 rt 5; a NULL rg with rt 15 (the NULL-lg
#                  left row's lt). No two rows of one rg share an rt, so
#                  which of two tied right rows matches (§3.19, undecided)
#                  is never asked.
#   weather        station, time, temp: NOT hand-written. BUCK stages Apache
#                  Avro's share/test/data/weather.json here (pinned by
#                  sha256 in third_party/apache-avro), upstream's own
#                  statement of the five records in its four weather .avro
#                  files. No case scans it; it is registered so test_corpus
#                  checks the schema scan_avro declares (`weather_schema`)
#                  against upstream's statement, member names, order and
#                  kinds, temp in INT32 range. The types are the Avro
#                  writer schema's (string, long, int; no union, so no
#                  NULL), as each file's header and upstream's
#                  share/test/schemas/weather.avsc spell it.
#                  A reader of these files must keep -0.0's sign (float_pairs,
#                  sort_rows) and read 9007199254740993 (2^53 + 1, avg_rows)
#                  as that exact INT64, never through a double. It must keep
#                  string bytes as written: no Unicode normalization
#                  (set_left and set_right differ only by it on k = 4).
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.json_source import JsonSource
from komira_scan_source.source_variant import SourceVariant

from .plan_case import INPUT_DIR, Dataset


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


def _set_side(name: String) -> Dataset:
    return Dataset(
        name,
        _schema(
            [String("id"), String("k"), String("s")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.STRING],
            [False, True, True],
        ),
    )


def set_left() -> Dataset:
    return _set_side("set_left")


def set_right() -> Dataset:
    return _set_side("set_right")


def str_rows() -> Dataset:
    return Dataset(
        "str_rows",
        _schema(
            [String("id"), String("s"), String("t")],
            [ArrowType.INT64, ArrowType.STRING, ArrowType.STRING],
            [False, True, True],
        ),
    )


def scan_rows_schema() -> Schema:
    return _schema(
        [String("id"), String("x"), String("s")],
        [ArrowType.INT64, ArrowType.INT64, ArrowType.STRING],
        [False, True, True],
    )


def scan_rows() -> Dataset:
    return Dataset("scan_rows", scan_rows_schema())


def scan_key_order() -> Dataset:
    return Dataset("scan_key_order", scan_rows_schema(), any_member_order=True)


def scan_sparse() -> Dataset:
    return Dataset(
        "scan_sparse",
        scan_rows_schema(),
        any_member_order=True,
        missing_ok=True,
        extra_members=[String("note")],
    )


def scan_numbers() -> Dataset:
    return Dataset(
        "scan_numbers",
        _schema(
            [String("id"), String("f")],
            [ArrowType.INT64, ArrowType.FLOAT64],
            [False, True],
        ),
    )


def frame_rows() -> Dataset:
    return Dataset(
        "frame_rows",
        _schema(
            [String("id"), String("g"), String("v"), String("w"), String("u")],
            [
                ArrowType.INT64, ArrowType.INT64, ArrowType.INT64,
                ArrowType.INT64, ArrowType.INT64,
            ],
            [False, False, True, False, True],
        ),
    )


def asof_left() -> Dataset:
    return Dataset(
        "asof_left",
        _schema(
            [String("lid"), String("lg"), String("lt")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [False, True, True],
        ),
    )


def asof_right() -> Dataset:
    return Dataset(
        "asof_right",
        _schema(
            [String("rid"), String("rg"), String("rt"), String("rv")],
            [ArrowType.INT64, ArrowType.INT64, ArrowType.INT64, ArrowType.INT64],
            [False, True, True, False],
        ),
    )


def weather_schema() -> Schema:
    """test.Weather as Avro's writer schema states it: station string, time
    long, temp int, none of them a union (so none nullable)."""
    return _schema(
        [String("station"), String("time"), String("temp")],
        [ArrowType.STRING, ArrowType.INT64, ArrowType.INT32],
        [False, False, False],
    )


def weather() -> Dataset:
    return Dataset("weather", weather_schema())


def all_datasets() -> List[Dataset]:
    """Every dataset a case may scan; test_corpus refuses a file under
    datasets/ that is not one of these."""
    return [
        bool_pairs(), ints_nullable(), groups(), join_left(), join_right(),
        sort_rows(), int_pairs(), window_rows(), rank_rows(), stat_rows(),
        avg_rows(), div_pairs(), float_pairs(), set_left(), set_right(),
        str_rows(), scan_rows(), scan_key_order(), scan_sparse(),
        scan_numbers(), frame_rows(), asof_left(), asof_right(), weather(),
    ]


# -----------------------------------------------------------------------------
# Inputs that are not JSON Lines: inputs/<format>/<file>
# -----------------------------------------------------------------------------
#
# The four Apache Avro interop files, staged by BUCK from
# //third_party/apache-avro (sha256-pinned, nothing committed here). Each
# holds the same five test.Weather records under a different block codec;
# upstream's own C++ test (lang/c++/test/DataFileTests.cc,
# testCompatibility) reads every one and checks the same records, which
# weather.json lists. A case names a file only through `avro_input`, which
# refuses a codec that is not here, and test_corpus requires every path
# below to be staged and every file under inputs/ to be one of them.


def avro_codecs() -> List[String]:
    return [String("null"), String("deflate"), String("snappy"), String("zstandard")]


def avro_input(codec: String) raises -> String:
    """The staged path of the weather file written with `codec`."""
    if codec == "null":
        return String(INPUT_DIR) + "/avro/weather.avro"
    if codec == "deflate":
        return String(INPUT_DIR) + "/avro/weather-deflate.avro"
    if codec == "snappy":
        return String(INPUT_DIR) + "/avro/weather-snappy.avro"
    if codec == "zstandard":
        return String(INPUT_DIR) + "/avro/weather-zstd.avro"
    raise Error("plan_conformance: no Avro weather file for codec '" + codec + "'")


def all_inputs() raises -> List[String]:
    """Every file a case may name under inputs/, as a path under the data
    root."""
    var res = List[String]()
    for c in avro_codecs():
        res.append(avro_input(c))
    return res^


def scan(ds: Dataset) raises -> LogicalPlan:
    """A scan of the whole dataset, through the JSON Lines source."""
    var src = JsonSource(ds.path(), ds.schema.copy())
    return LogicalPlan.scan_from_source(SourceVariant(src^), ds.schema.copy())
