from pathlib import Path

import komira
from komira import pl

Path("scores.csv").write_text(
    "name,q1,q2,q3\n"
    "Ana,10,20,30\n"
    "Bo,5,,7\n"
    "Cy,1,2,3\n"
)

# SQL: one SELECT per column to melt, stacked with UNION ALL.
with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    long = s.sql(
        "SELECT name, 'q1' AS quarter, q1 AS score FROM scores"
        " UNION ALL SELECT name, 'q2', q2 FROM scores"
        " UNION ALL SELECT name, 'q3', q3 FROM scores"
        " ORDER BY name, quarter"
    )
    print(long.to_arrow().to_pylist())

# pandas-shaped: melt, every column not in id_vars becoming rows.
df = komira.read_csv("scores.csv")
long = df.melt(id_vars=["name"], var_name="quarter", value_name="score")
print(long.sort_values(["name", "quarter"]).materialize().to_arrow().to_pylist())

# polars-shaped: unpivot, the same with polars' names.
lf = pl.scan_csv("scores.csv")
long = lf.unpivot(["q1", "q2", "q3"], index="name", variable_name="quarter", value_name="score")
print(long.sort("name", "quarter").collect().to_arrow().to_pylist())

# Without the missing scores: drop the rows whose score is missing.
print(long.drop_nulls("score").sort("name", "quarter").collect().to_arrow().to_pylist())
