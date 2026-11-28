"""`Series.round` on the real libkomira: each frame runs through
komira_plan_stream over a Parquet file written here, and its rows are compared
with the rows worked out by hand:

- test_float_halves_round_to_even: 0.5 gives 0.0, 1.5 gives 2.0, 2.5 gives 2.0,
  -2.5 gives -2.0, and NULL stays NULL (SQL's round(x, d) gives 1, 2, 3, -3
  for the same halves);
- test_float_digits: round(1) of 2.25 is 2.2 and of 2.35 is 2.4, round(2) of
  1.005 is 1.0, and the result is float64;
- test_a_negative_count_rounds_left_of_the_point: round(-1) of 25.0 is 20.0 and
  of 35.0 is 40.0, round(-2) of 150.0 is 200.0;
- test_integers_are_unchanged_for_a_count_of_zero_or_more: the int64 values and
  the type are the column's;
- test_integers_round_to_even_left_of_the_point: round(-2) of 1250 is 1200
  (SQL's round(1250, -2) is 1300), of 1350 is 1400, of -1250 is -1200, int64;
- test_float32_stays_float32: the type is float32 and 2.5 gives 2.0;
- test_a_float_column_rounds_inside_an_expression: a filter and an assignment
  use the rounded column.

The test is of the `run/` family (python/tests/BUCK): `series_round_run_test`
runs on the real libkomira on each supported minor, with the generated plan
modules, protobuf 7.36.2 and pyarrow.

    test_series_round_run.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which
the rule passes, is not read).
"""

import contextlib
import os
import sys
import tempfile

import pyarrow as pa
import pyarrow.parquet as pq

import komira
from komira import _native

IDS = [1, 2, 3, 4, 5, 6, 7]
HALVES = [0.5, 1.5, 2.5, -2.5, None, -0.5, 3.5]
TENTHS = [2.25, 2.35, 1.005, None, 0.05, -2.25, 10.0]
TENS = [25.0, 35.0, 150.0, 5.0, None, -25.0, 149.0]
BIG = [1250, 1350, -1250, 1249, None, 0, 49]
SMALL = [3, None, -4, 5, 6, 7, 8]
SINGLES = [0.5, 1.5, 2.5, -2.5, None, 0.25, 3.5]


@contextlib.contextmanager
def frame():
    """A session and a frame over the file, in a directory removed afterwards."""
    table = pa.table(
        {
            "id": pa.array(IDS, pa.int64()),
            "halves": pa.array(HALVES, pa.float64()),
            "tenths": pa.array(TENTHS, pa.float64()),
            "tens": pa.array(TENS, pa.float64()),
            "big": pa.array(BIG, pa.int64()),
            "small": pa.array(SMALL, pa.int32()),
            "single": pa.array(SINGLES, pa.float32()),
        }
    )
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "values.parquet")
        pq.write_table(table, path, row_group_size=3)
        with komira.Session() as s:
            yield komira.read_parquet(path, session=s)


def column(df, name):
    """The values of column `name` of `df`, in `id` order, and its Arrow type."""
    t = df.materialize().to_arrow()
    rows = sorted(t.to_pylist(), key=lambda r: r["id"])
    return [r[name] for r in rows], t.schema.field(name).type


def test_float_halves_round_to_even(lib_dir):
    with frame() as df:
        got, kind = column(df.assign(v=df["halves"].round()), "v")
        assert got == [0.0, 2.0, 2.0, -2.0, None, -0.0, 4.0], got
        assert kind == pa.float64(), kind
        assert df["halves"].round().dtype == "float64"


def test_float_digits(lib_dir):
    with frame() as df:
        got, kind = column(df.assign(v=df["tenths"].round(1)), "v")
        assert got == [2.2, 2.4, 1.0, None, 0.0, -2.2, 10.0], got
        assert kind == pa.float64(), kind
        got, _ = column(df.assign(v=df["tenths"].round(2)), "v")
        assert got == [2.25, 2.35, 1.0, None, 0.05, -2.25, 10.0], got


def test_a_negative_count_rounds_left_of_the_point(lib_dir):
    with frame() as df:
        got, _ = column(df.assign(v=df["tens"].round(-1)), "v")
        assert got == [20.0, 40.0, 150.0, 0.0, None, -20.0, 150.0], got
        got, _ = column(df.assign(v=df["tens"].round(-2)), "v")
        assert got == [0.0, 0.0, 200.0, 0.0, None, -0.0, 100.0], got


def test_integers_are_unchanged_for_a_count_of_zero_or_more(lib_dir):
    with frame() as df:
        for count in (0, 1, 5):
            got, kind = column(df.assign(v=df["big"].round(count)), "v")
            assert got == BIG, (count, got)
            assert kind == pa.int64(), kind
        got, kind = column(df.assign(v=df["small"].round()), "v")
        assert got == SMALL and kind == pa.int32(), (got, kind)


def test_integers_round_to_even_left_of_the_point(lib_dir):
    with frame() as df:
        got, kind = column(df.assign(v=df["big"].round(-2)), "v")
        assert got == [1200, 1400, -1200, 1200, None, 0, 0], got
        assert kind == pa.int64(), kind


def test_float32_stays_float32(lib_dir):
    with frame() as df:
        got, kind = column(df.assign(v=df["single"].round()), "v")
        assert got == [0.0, 2.0, 2.0, -2.0, None, 0.0, 4.0], got
        assert kind == pa.float32(), kind


def test_a_float_column_rounds_inside_an_expression(lib_dir):
    with frame() as df:
        kept = df[df["halves"].round() == 2.0]
        got = sorted(r["id"] for r in kept.materialize().to_arrow().to_pylist())
        assert got == [2, 3], got
        got, _ = column(df.assign(v=df["halves"].round() * 10), "v")
        assert got == [0.0, 20.0, 20.0, -20.0, None, -0.0, 40.0], got


TESTS = [
    test_float_halves_round_to_even,
    test_float_digits,
    test_a_negative_count_rounds_left_of_the_point,
    test_integers_are_unchanged_for_a_count_of_zero_or_more,
    test_integers_round_to_even_left_of_the_point,
    test_float32_stays_float32,
    test_a_float_column_rounds_inside_an_expression,
]


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1008, komira.abi_version()
    for test in TESTS:
        test(lib_dir)
        print("ok", test.__name__)
    print("series round: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
