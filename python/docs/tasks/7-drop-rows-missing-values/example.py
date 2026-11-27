from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira
import komira.pl as kpl

# A small CSV file: an empty field reads as NULL.
Path("people.csv").write_text(
    "id,name,score,city\n"
    "1,Ana,9.5,Oslo\n"
    "2,Bo,,Lima\n"
    "3,,7.0,\n"
    "4,,,Rome\n"
    "5,,,\n"
)

# SQL: keep the rows whose values are not NULL.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    complete = s.sql(
        "SELECT * FROM people"
        " WHERE name IS NOT NULL AND score IS NOT NULL AND city IS NOT NULL"
    )
    print(complete.to_arrow().to_pylist())
    scored = s.sql("SELECT * FROM people WHERE score IS NOT NULL ORDER BY id")
    print(scored.to_arrow().to_pylist())
    either = s.sql(
        "SELECT id FROM people WHERE name IS NOT NULL OR score IS NOT NULL ORDER BY id"
    )
    print(either.to_arrow().to_pylist())

# pandas-shaped: dropna keeps the rows with no missing value, or with none in
# the columns of subset=, or (how="all") with a value in at least one of them.
df = komira.read_csv("people.csv")
print(df.dropna().materialize().to_arrow().to_pylist())
print(df.dropna(subset=["score"]).sort_values("id").materialize().to_arrow().to_pylist())
any_value = df.dropna(how="all", subset=["name", "score"])[["id"]]
print(any_value.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: drop_nulls, with a column name or a list of them for a subset.
lf = kpl.scan_csv("people.csv")
print(lf.drop_nulls().collect().to_arrow().to_pylist())
print(lf.drop_nulls("score").sort("id").collect().to_arrow().to_pylist())

# NaN in a float column is missing too in the pandas-shaped frame, as NULL is.
pq.write_table(pa.table({"id": [1, 2, 3], "x": [1.5, float("nan"), None]}), "x.parquet")
print(komira.read_parquet("x.parquet").dropna().materialize().to_arrow().to_pylist())
