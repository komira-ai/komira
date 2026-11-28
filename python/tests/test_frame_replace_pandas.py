"""`DataFrame.replace` and `Series.replace` held to pandas (`frame_replace_pandas_test`,
CPython 3.13, the real libkomira and the pinned pandas 3). Each program is
one Python function that runs on a pandas DataFrame and on a komira
DataFrame alike; pandas runs it on the file read with pyarrow's `to_pandas()`,
and komira on the same Parquet file, through its plan door. Checked:

- the file: a name, a city with the placeholders "N/A", "n/a" and "-", an
  empty string and a NULL; an int64 score with -1 placeholders and no NULL;
  an int32 count with no NULL; a float64 ratio with -1.0, NaN and a NULL; a
  float32 weight holding 0.1 as float32 rounds it;
- the programs: a list of placeholders to None; a scalar to None over every
  column; a dict of columns; a nested dict; a flat {old: new} dict; a dict
  value per column; two lists pairwise, where a replaced value is not looked
  for again; a value given twice, which takes its last replacement; NaN to a
  number in the float column; None looked for in the float column, which
  meets nothing, and in the string column, which meets the NULL; a float the
  float32 column holds rounded; a whole float meeting the int columns; a
  value no column holds; Series.replace assigned as a column;
- every cell equal by column, pandas' NaN, None and NA against komira's NULL
  (or NaN in a float column, which pandas does not tell from NULL), ints,
  strings and floats exactly; and komira's column types are the file's,
  where pandas may widen a column to object or float64.

    test_frame_replace_pandas.py --lib-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import math
import os
import sys
import tempfile

import komira
from komira import _native

CITY = ["Oslo", "N/A", "n/a", "-", "", None, "Lima", "N/A"]
SCORE = [8, -1, 6, -1, 0, 1, 2, 3]
COUNT = [1, 2, 3, 4, 5, 6, 7, 8]
RATIO = [0.5, -1.0, math.nan, None, 1.0, 0.1, 2.0, -1.0]
WEIGHT = [0.1, 1.0, None, 0.1, 2.5, 0.25, -1.0, 3.0]
TYPES = ["string", "string", "int64", "int32", "double", "float"]


def write_data(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pa.table(
        {
            "name": pa.array([f"p{i}" for i in range(len(CITY))], pa.string()),
            "city": pa.array(CITY, pa.string()),
            "score": pa.array(SCORE, pa.int64()),
            "count": pa.array(COUNT, pa.int32()),
            "ratio": pa.array(RATIO, pa.float64()),
            "weight": pa.array(WEIGHT, pa.float32()),
        }
    )
    pq.write_table(table, path)
    return path


PROGRAMS = [
    ("a list of placeholders to None", lambda d: d.replace(["N/A", "n/a", "-"], None)),
    ("a scalar to None over every column", lambda d: d.replace(-1, None)),
    ("a dict of columns", lambda d: d.replace({"city": ["N/A", "-"], "score": -1}, None)),
    ("a nested dict", lambda d: d.replace({"city": {"N/A": None, "Oslo": "OSL"}, "count": {1: 10}})),
    ("a flat dict of old to new", lambda d: d.replace({"N/A": None, -1: 0})),
    ("a dict value per column", lambda d: d.replace(-1, {"score": None, "ratio": 0})),
    ("two lists pairwise, a replaced value not looked for again", lambda d: d.replace([1, 2], [2, 3])),
    ("a value given twice takes its last replacement", lambda d: d.replace([-1, -1.0], [5, 6])),
    ("NaN to a number in the float column", lambda d: d.replace({"ratio": math.nan}, 0)),
    ("None in the float column meets nothing", lambda d: d.replace({"ratio": [None]}, 0)),
    ("None in the string column meets the NULL", lambda d: d.replace({"city": [None]}, "?")),
    ("a float the float32 column holds rounded", lambda d: d.replace(0.1, 0.2)),
    ("a whole float meets the int columns", lambda d: d.replace(2.0, None)),
    ("a value no column holds", lambda d: d.replace(12345, None)),
    (
        "Series.replace assigned as a column",
        lambda d: d.assign(city=d["city"].replace(["N/A", "n/a"], None), score=d["score"].replace(-1, None)),
    ),
]


def is_missing(x):
    if x is None:
        return True
    try:
        import pandas

        return bool(pandas.isna(x))
    except (TypeError, ValueError):
        return False


def cell_equal(got, want):
    """komira's cell `got` against pandas' `want`: both missing (pandas does
    not tell NaN from NULL), or equal values of one kind."""
    if is_missing(got) or is_missing(want):
        return is_missing(got) and is_missing(want)
    if isinstance(got, float) or isinstance(want, float):
        return float(got) == float(want)
    return type(got) is type(want) and got == want


def pandas_answer(frame):
    out = {}
    for name in frame.columns:
        values = []
        for x in frame[name].tolist():
            values.append(x.item() if hasattr(x, "item") else x)
        out[name] = values
    return out


FAILED = []


def check(name, program, path, session):
    import pyarrow.parquet as pq

    want = pandas_answer(program(pq.read_table(path).to_pandas()))
    table = program(komira.read_parquet(path, session=session)).materialize().to_arrow()
    got = table.to_pydict()
    if list(got) != list(want):
        FAILED.append(f"{name}: columns {list(got)}, pandas {list(want)}")
        return
    types = [str(t) for t in table.schema.types]
    if types != TYPES:
        FAILED.append(f"{name}: komira's types {types}, the file's {TYPES}")
    for column in got:
        g, w = got[column], want[column]
        if len(g) != len(w) or not all(cell_equal(a, b) for a, b in zip(g, w)):
            FAILED.append(f"{name}: column {column!r} is {g}, pandas {w}")


def test_the_comparator_tells_a_value_from_a_null_and_equates_nan_with_null():
    assert cell_equal(None, None) and cell_equal(math.nan, None) and cell_equal(None, math.nan)
    assert cell_equal(1, 1) and cell_equal(0.5, 0.5) and cell_equal("a", "a") and cell_equal(2, 2.0)
    assert not cell_equal(None, 1) and not cell_equal(1, None) and not cell_equal("", None)
    assert not cell_equal(1, 2) and not cell_equal("1", 1) and not cell_equal(0.1, 0.10000000149011612)


def test_the_file_has_the_placeholders_and_missing_values_the_programs_need(path):
    import pyarrow.parquet as pq

    table = pq.read_table(path)
    assert [str(t) for t in table.schema.types] == TYPES, table.schema
    frame = table.to_pandas()
    # pandas keeps the int columns as ints (no NULL in them) and reads the
    # float32 column as float32.
    assert [str(t) for t in frame.dtypes][2:] == ["int64", "int32", "float64", "float32"], frame.dtypes
    assert {"N/A", "n/a", "-", ""} <= set(x for x in CITY if x is not None) and None in CITY
    assert -1 in SCORE and None not in SCORE and None not in COUNT
    assert None in RATIO and any(isinstance(x, float) and math.isnan(x) for x in RATIO)


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    test_the_comparator_tells_a_value_from_a_null_and_equates_nan_with_null()
    # The library is loaded before pyarrow and pandas are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        path = write_data(os.path.join(work, "contacts.parquet"))
        test_the_file_has_the_placeholders_and_missing_values_the_programs_need(path)
        with komira.Session() as session:
            for name, program in PROGRAMS:
                try:
                    check(name, program, path, session)
                except (AssertionError, komira.KomiraError) as e:
                    FAILED.append(f"{name}: {type(e).__name__}: {e}")
    assert not FAILED, "{} programs differ from pandas:\n".format(len(FAILED)) + "\n".join(FAILED)
    print("frame replace pandas: {} programs".format(len(PROGRAMS)))


if __name__ == "__main__":
    main(sys.argv[1:])
