from pathlib import Path

import komira
from komira import pl

Path("people.csv").write_text(
    "id,name,city\n"
    "1,Ana,Oslo\n"
    "2,Bo,Rome\n"
    "1,Ana,Oslo\n"
    "3,Cy,Oslo\n"
    "2,Bo,Rome\n"
    "4,Ana,Lima\n"
)

# SQL: DISTINCT drops rows equal on every column.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    print(s.sql("SELECT DISTINCT id, name, city FROM people ORDER BY id").to_arrow().to_pylist())

    # One row per name: number the rows of each name, keep number 1.
    first = s.sql(
        "SELECT id, name, city FROM ("
        " SELECT id, name, city,"
        " row_number() OVER (PARTITION BY name ORDER BY id) AS n FROM people"
        ") d WHERE n = 1 ORDER BY id"
    )
    print(first.to_arrow().to_pylist())

# pandas-shaped: drop_duplicates() on whole rows; keep=False drops every copy.
df = komira.read_csv("people.csv")
print(df.drop_duplicates().sort_values("id").materialize().to_arrow().to_pylist())
print(df.drop_duplicates(keep=False).sort_values("id").materialize().to_arrow().to_pylist())

# One whole row per name: subset= compares only the named columns. Any one row
# of each name is kept (a plan has no row order), so print the names and columns.
one = df.drop_duplicates(subset=["name"]).sort_values("name").materialize().to_arrow().to_pylist()
print([r["name"] for r in one], list(one[0]))

# keep=False keeps the rows whose name no other row has; duplicated() marks rows.
print(df.drop_duplicates(subset=["name"], keep=False).materialize().to_arrow().to_pylist())
print(df[df.duplicated("name", keep=False)].sort_values("id").materialize().to_arrow().to_pylist())

# Only the names: select the column first.
print(df[["name"]].drop_duplicates().sort_values("name").materialize().to_arrow().to_pylist())

# polars-shaped: unique() on whole rows, or on a subset of columns.
lf = pl.scan_csv("people.csv")
print(lf.unique().sort("id").collect().to_arrow().to_pylist())
print(lf.unique(subset=["name"]).select("name").sort("name").collect().to_arrow().to_pylist())
