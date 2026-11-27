from pathlib import Path

import komira

Path("people.csv").write_text(
    "id,name\n"
    '1,"  Ana SMITH "\n'
    "2,bo-JONES\n"
    '3," cy   LEE"\n'
)

# SQL: lower, trim and replace compose as functions.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    clean = s.sql(
        "SELECT id, replace(lower(trim(name)), '-', ' ') AS name"
        " FROM people ORDER BY id"
    )
    print(clean.to_arrow().to_pylist())

# pandas-shaped: .str.lower() and .str.replace() (trimming is not here yet).
df = komira.read_csv("people.csv")
df["name"] = df["name"].str.lower().str.replace("-", " ", regex=False)
print(df.sort_values("id").materialize().to_arrow().to_pylist())
