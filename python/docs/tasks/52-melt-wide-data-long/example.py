from pathlib import Path

import komira

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

# pandas-shaped: one frame per column, stacked with concat.
df = komira.read_csv("scores.csv")
parts = [
    df.assign(quarter=col, score=df[col])[["name", "quarter", "score"]]
    for col in ["q1", "q2", "q3"]
]
long = komira.concat(parts)
print(long.dropna(subset=["score"]).sort_values(["name", "quarter"]).materialize().to_arrow().to_pylist())
