from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira
import komira.pl as kpl

# A small Parquet file to read: a null in the file reads as NULL.
pq.write_table(
    pa.table(
        {
            "id": [3, 1, 2],
            "name": ["Cy", "Ana", "Bo"],
            "score": [None, 9.5, 7.0],
        }
    ),
    "people.parquet",
)

# SQL: register the file as a table, or name it in the query.
with komira.Session() as s:
    s.register_parquet("people", "people.parquet")
    print(s.sql("SELECT * FROM people ORDER BY id").to_arrow().to_pylist())
    print(s.sql("SELECT name FROM read_parquet('people.parquet') ORDER BY name").to_arrow().to_pylist())
    print(s.sql("SELECT count(*) AS n FROM 'people.parquet'").to_arrow().to_pylist())

# pandas-shaped: komira.read_parquet reads the schema from the file's footer
# now and the rows when the frame runs.
df = komira.read_parquet(Path("people.parquet"))
print(df.columns)
print(df.dtypes["id"], df.dtypes["name"], df.dtypes["score"])
print(df[["id", "name"]].sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: scan_parquet is lazy; collect() runs it.
lf = kpl.scan_parquet("people.parquet")
print(lf.select("id", "score").sort("id").collect().to_arrow().to_pylist())
