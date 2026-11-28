from pathlib import Path

import komira
import komira.pl as kpl

# Row 4 starts with a tab and ends with a non-breaking space.
Path("people.csv").write_text(
    "id,name\n"
    '1,"  Ana SMITH "\n'
    "2,bo-JONES\n"
    '3," cy   LEE"\n'
    '4,"\tDi-RAY\xa0"\n'
)

# SQL: lower, trim and replace compose as functions. trim(name) removes
# spaces only, so the tab and the non-breaking space of row 4 stay.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    clean = s.sql(
        "SELECT id, replace(lower(trim(name)), '-', ' ') AS name"
        " FROM people ORDER BY id"
    )
    print(clean.to_arrow().to_pylist())

# pandas-shaped: .str.strip() removes all whitespace, as Python's str.strip()
# does: spaces, the tab and the non-breaking space.
df = komira.read_csv("people.csv")
df["name"] = df["name"].str.strip().str.lower().str.replace("-", " ", regex=False)
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: str.strip_chars(), then str.replace() of the first match.
lf = kpl.scan_csv("people.csv").with_columns(kpl.col("name").str.strip_chars().str.to_lowercase())
lf = lf.with_columns(kpl.col("name").str.replace("-", " ", literal=True))
print(lf.sort("id").collect().to_arrow().to_pylist())
