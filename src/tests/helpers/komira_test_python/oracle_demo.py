"""The two live oracles agree with fixed answers: DuckDB sums, pyarrow round-trips an IPC stream.

DuckDB computes SUM over a three-row table and must return exactly 60 (an
int128 sum of BIGINT, returned as a Python int). pyarrow writes a two-column
record batch as an IPC stream to a file and reads it back; the batch read
must equal the batch written, column for column, with the schema intact.
"""

import os
import tempfile

import duckdb
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


duckdb_sum()
arrow_ipc_round_trip()
