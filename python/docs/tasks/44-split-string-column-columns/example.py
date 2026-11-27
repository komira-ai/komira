from pathlib import Path

import komira

Path("people.csv").write_text("id,full_name\n1,Ana Smith\n2,Bo Lee\n3,Cy\n")

# SQL: one regexp_extract per part, each taking one capture group of the
# same pattern. A part the string lacks is ''.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    sql = (
        "SELECT id,"
        " regexp_extract(full_name, '^(\\S+) ?(.*)$', 1) AS first,"
        " regexp_extract(full_name, '^(\\S+) ?(.*)$', 2) AS last"
        " FROM people ORDER BY id"
    )
    for row in s.sql(sql).to_arrow().to_pylist():
        print(row)

# pandas-shaped: str.extract with expand=False gives one part per call.
df = komira.read_csv("people.csv")
name = df["full_name"].str
df = df.assign(
    first=name.extract(r"^(\S+)", expand=False),
    last=name.extract(r"^\S+ ?(.*)$", expand=False),
)
print(df.sort_values("id").materialize().to_arrow().to_pylist())
