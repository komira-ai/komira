from pathlib import Path

import komira
import komira.pl as pl

Path("people.csv").write_text(
    "id,name,email\n"
    "1,Ana,ana@example.com\n"
    "2,Bo,bo@example.com\n"
    "3,Ana B,ana@example.com\n"
    "4,Cy,cy@example.com\n"
    "5,Bo,bo@example.com\n"
    "6,Bo,bo@example.com\n"
)

# SQL: group by the columns that define a duplicate and keep groups seen twice or more.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    keys = s.sql(
        "SELECT email, count(*) AS n FROM people"
        " GROUP BY email HAVING count(*) > 1 ORDER BY email"
    )
    print(keys.to_arrow().to_pylist())

    # A window count keeps every row of each duplicated group, whole.
    rows = s.sql(
        "SELECT id, name, email FROM"
        " (SELECT id, name, email, count(*) OVER (PARTITION BY email) AS n FROM people)"
        " WHERE n > 1 ORDER BY id"
    )
    print(rows.to_arrow().to_pylist())

    # Only the extra copies: number the rows in each group and keep the later ones.
    extra = s.sql(
        "SELECT id, name, email FROM"
        " (SELECT id, name, email,"
        "  row_number() OVER (PARTITION BY name, email ORDER BY id) AS rn FROM people)"
        " WHERE rn > 1 ORDER BY id"
    )
    print(extra.to_arrow().to_pylist())

# pandas-shaped: count each row's group, then keep rows whose group has more than one.
df = komira.read_csv("people.csv")
dups = df[df.groupby("email")["id"].transform("count") > 1]
print(dups.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: a window count over the key.
lf = pl.scan_csv("people.csv")
print(lf.filter(pl.len().over("email") > 1).sort("id").collect().to_arrow().to_pylist())
