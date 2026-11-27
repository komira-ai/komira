from pathlib import Path

import komira
import komira.pl as kpl

# A small CSV file: the last fare is empty, so it reads as NULL.
Path("trips.csv").write_text(
    "id,city,km,fare\n"
    "1,Oslo,3,12.5\n"
    "2,Lima,8,20.0\n"
    "3,Oslo,5,7.5\n"
    "4,Rome,2,30.0\n"
    "5,Lima,11,\n"
)

# SQL: count(*) counts the rows, ORDER BY with LIMIT takes the first rows.
with komira.Session() as s:
    s.register_csv("trips", "trips.csv")
    print(s.sql("SELECT count(*) AS n FROM trips").to_arrow().to_pylist())
    for row in s.sql("SELECT * FROM trips ORDER BY id LIMIT 2").to_arrow().to_pylist():
        print(row)

# pandas-shaped: the column names and types are known without running a query.
df = komira.read_csv("trips.csv")
print(df.columns)
print(df.dtypes["id"], df.dtypes["km"], df.dtypes["fare"])

# The first rows of a sorted frame. An unsorted frame has no first rows.
print(df.sort_values("id").head(2).materialize().to_arrow().to_pylist())

# The row count is a reduction: "size" counts rows, count() counts the
# values that are not NULL in each column.
print(df.agg(n=("id", "size")).materialize().to_arrow().to_pylist())
print(df.count().materialize().to_arrow().to_pylist())

# polars-shaped: the same, with kpl.len() for the row count.
lf = kpl.scan_csv("trips.csv")
print(lf.columns)
print(lf.sort("id").head(2).collect().to_arrow().to_pylist())
print(lf.select(kpl.len()).collect().to_arrow().to_pylist())
