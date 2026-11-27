from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira
import komira.pl as pl

# Every column here starts as text, as it does in many exported files.
pq.write_table(
    pa.table(
        {
            "id": ["1", "2", "3"],
            "price": ["1.5", "2.25", "10"],
            "qty": ["3", "4", "5"],
        }
    ),
    "items.parquet",
)

# pandas-shaped: astype takes one dtype per column, or one dtype for a Series.
df = komira.read_parquet("items.parquet")
typed = df.astype({"id": "int64", "price": "float64", "qty": "int32"})
print(typed.dtypes)
print(typed.sort_values("id").materialize().to_arrow().to_pylist())
print(df["id"].astype("int64").dtype)

# polars-shaped: cast a column in with_columns.
lf = pl.scan_parquet("items.parquet").with_columns(
    pl.col("id").cast("int64"),
    pl.col("price").cast("float64"),
    pl.col("qty").cast("int32"),
)
print({f.name: str(f.type) for f in lf.collect().to_arrow().schema})

# SQL: CAST(x AS type) or x::type, here from numbers to text and to double.
Path("nums.csv").write_text("id,qty\n1,3\n2,4\n3,5\n")
with komira.Session() as s:
    s.register_csv("nums", "nums.csv")
    rows = s.sql(
        "SELECT CAST(id AS VARCHAR) AS id, qty::DOUBLE AS qty FROM nums ORDER BY qty"
    )
    print(rows.to_arrow().to_pylist())
