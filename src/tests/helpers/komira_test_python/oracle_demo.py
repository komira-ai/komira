"""The live oracles agree with fixed answers, and polars and pandas read pyarrow's data.

DuckDB computes SUM over a three-row table and must return exactly 60 (an
int128 sum of BIGINT, returned as a Python int). pyarrow writes a two-column
record batch as an IPC stream to a file and reads it back; the batch read
must equal the batch written, column for column, with the schema intact.
polars (1.44.2) takes that table from Arrow, sums `id` to exactly 6 and hands
back the same values through Arrow and through pandas (pyarrow, polars, pandas
and numpy at their pins, working together).
"""

import os
import tempfile

import duckdb
import polars as pl
import pyarrow as pa
import pyarrow.ipc as ipc


def duckdb_sum():
    con = duckdb.connect()
    con.execute("CREATE TABLE t (v BIGINT)")
    con.execute("INSERT INTO t VALUES (10), (20), (30)")
    got = con.execute("SELECT SUM(v) FROM t").fetchall()
    assert got == [(60,)], "duckdb SUM is {!r}, want [(60,)]".format(got)
    print("duckdb SUM(v) =", got[0][0])


def arrow_ipc_round_trip():
    batch = pa.record_batch(
        [pa.array([1, 2, 3], type=pa.int64()), pa.array(["a", None, "c"], type=pa.string())],
        names=["id", "name"],
    )
    path = os.path.join(tempfile.gettempdir(), "batch.arrows")
    with pa.OSFile(path, "wb") as sink, ipc.new_stream(sink, batch.schema) as writer:
        writer.write_batch(batch)
    with pa.OSFile(path, "rb") as source:
        table = ipc.open_stream(source).read_all()
    assert table.schema == batch.schema, "schema {} != {}".format(table.schema, batch.schema)
    assert table.to_pydict() == {"id": [1, 2, 3], "name": ["a", None, "c"]}, table.to_pydict()
    assert table.num_rows == 3 and table.column("id").to_pylist() == [1, 2, 3]
    print("pyarrow IPC stream round trip:", table.to_pydict())
    return table


def polars_from_arrow(table):
    df = pl.from_arrow(table)
    assert df.columns == ["id", "name"], df.columns
    assert df["id"].sum() == 6, "polars sum is {!r}, want 6".format(df["id"].sum())
    want = {"id": [1, 2, 3], "name": ["a", None, "c"]}
    assert df.to_arrow().to_pydict() == want, df.to_arrow().to_pydict()
    pdf = df.to_pandas()
    got = {"id": pdf["id"].tolist(), "name": [None if v is None or v != v else v for v in pdf["name"].tolist()]}
    assert got == want, "polars -> pandas is {!r}, want {!r}".format(got, want)
    print("polars", pl.__version__, "from Arrow: sum(id) = 6, back through Arrow and pandas")


duckdb_sum()
polars_from_arrow(arrow_ipc_round_trip())
