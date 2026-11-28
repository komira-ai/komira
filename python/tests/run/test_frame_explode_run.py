"""`DataFrame.explode` and SQL `unnest` on the real libkomira, over a Parquet
file written here with list columns (a list column cannot be read from JSON):
`id` int64, `tags` list<string> and `nums` list<int64>, holding a list of
several elements, an empty list, a NULL list, a list with a NULL element and a
one-element list. Checked:

- `df.explode("tags")` gives the pandas rows: an element per row with the
  other columns repeated, an empty and a NULL list each one row holding NULL,
  a NULL element a row holding NULL, elements in list order;
- `df.explode("nums")` does the same for an int64 element, with the column's
  type int64;
- two explodes one after the other multiply the rows of a row;
- a frame sorted by `id` keeps its order through `explode`;
- `SELECT id, unnest(tags) AS tag FROM t` has the DuckDB rows: an empty and a
  NULL list give no row, a NULL element gives a row holding NULL.

The test is of the `run/` family (python/tests/BUCK).

    test_frame_explode_run.py --lib-dir <dir> --runtime-dir <dir>
"""

import os
import sys
import tempfile

import pyarrow as pa
import pyarrow.parquet as pq

import komira
from komira import _native

IDS = [1, 2, 3, 4, 5]
TAGS = [["a", "b", "c"], [], None, ["d", None], ["e"]]
NUMS = [[10, 20], [], None, [30], [40, 50, 60]]


def write_file(work):
    table = pa.table(
        {
            "id": pa.array(IDS, pa.int64()),
            "tags": pa.array(TAGS, pa.list_(pa.string())),
            "nums": pa.array(NUMS, pa.list_(pa.int64())),
        }
    )
    path = os.path.join(work, "lists.parquet")
    pq.write_table(table, path)
    return path


def key(row):
    return tuple(str(v) for v in row.values())


def sorted_rows(rows):
    return sorted(rows, key=key)


def test_explode_a_string_list_column(lib_dir):
    with tempfile.TemporaryDirectory() as work, komira.Session() as s:
        df = komira.read_parquet(write_file(work), session=s)
        rows = df.explode("tags").materialize().to_arrow().to_pylist()
    nums = dict(zip(IDS, NUMS))
    expected = [
        {"id": i, "tags": tag, "nums": nums[i]}
        for i, tag in [(1, "a"), (1, "b"), (1, "c"), (2, None), (3, None), (4, "d"), (4, None), (5, "e")]
    ]
    assert sorted_rows(rows) == sorted_rows(expected), rows


def test_explode_an_int_list_column_gives_an_int_column(lib_dir):
    with tempfile.TemporaryDirectory() as work, komira.Session() as s:
        df = komira.read_parquet(write_file(work), session=s)
        out = df.explode("nums")
        assert out.dtypes["nums"] == "int64" and out.dtypes["tags"] == "list"
        rows = out.materialize().to_arrow().to_pylist()
    tags = dict(zip(IDS, TAGS))
    pairs = [(1, 10), (1, 20), (2, None), (3, None), (4, 30), (5, 40), (5, 50), (5, 60)]
    expected = [{"id": i, "tags": tags[i], "nums": n} for i, n in pairs]
    assert sorted_rows(rows) == sorted_rows(expected), rows


def test_two_explodes_multiply_the_rows_of_a_row(lib_dir):
    with tempfile.TemporaryDirectory() as work, komira.Session() as s:
        df = komira.read_parquet(write_file(work), session=s)
        rows = df.explode("tags").explode("nums").materialize().to_arrow().to_pylist()
    assert len([r for r in rows if r["id"] == 1]) == 6, rows
    assert len([r for r in rows if r["id"] == 5]) == 3, rows
    assert len(rows) == 6 + 1 + 1 + 2 + 3, rows


def test_a_sorted_frame_keeps_its_order_through_explode(lib_dir):
    with tempfile.TemporaryDirectory() as work, komira.Session() as s:
        df = komira.read_parquet(write_file(work), session=s)
        rows = df.sort_values("id", ascending=False).explode("tags").materialize().to_arrow().to_pylist()
    got = [r["id"] for r in rows]
    assert got == sorted(got, reverse=True) and got == [5, 4, 4, 3, 2, 1, 1, 1], got
    assert [r["tags"] for r in rows if r["id"] == 1] == ["a", "b", "c"], rows


def test_sql_unnest_drops_empty_and_null_lists(lib_dir):
    with tempfile.TemporaryDirectory() as work, komira.Session() as s:
        s.register_parquet("t", write_file(work))
        rows = s.sql("SELECT id, unnest(tags) AS tag FROM t ORDER BY id, tag").to_arrow().to_pylist()
    expected = [
        {"id": 1, "tag": "a"},
        {"id": 1, "tag": "b"},
        {"id": 1, "tag": "c"},
        {"id": 4, "tag": "d"},
        {"id": 4, "tag": None},
        {"id": 5, "tag": "e"},
    ]
    assert sorted_rows(rows) == sorted_rows(expected), rows
    assert [r["id"] for r in rows] == [1, 1, 1, 4, 4, 5], rows


TESTS = [
    test_explode_a_string_list_column,
    test_explode_an_int_list_column_gives_an_int_column,
    test_two_explodes_multiply_the_rows_of_a_row,
    test_a_sorted_frame_keeps_its_order_through_explode,
    test_sql_unnest_drops_empty_and_null_lists,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    for test in TESTS:
        test(lib_dir)
        print("ok", test.__name__)


if __name__ == "__main__":
    main(sys.argv[1:])
