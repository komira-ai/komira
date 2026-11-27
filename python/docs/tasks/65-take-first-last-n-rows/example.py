from pathlib import Path

import komira
import komira.pl as pl

Path("scores.csv").write_text(
    "id,name,score\n"
    "1,Ana,72\n"
    "2,Bo,95\n"
    "3,Cy,60\n"
    "4,Di,88\n"
    "5,Ed,79\n"
    "6,Flo,91\n"
)

# SQL: the order in ORDER BY, the count in LIMIT. DESC turns first into last.
with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    top3 = s.sql("SELECT * FROM scores ORDER BY score DESC LIMIT 3")
    print(top3.to_arrow().to_pylist())
    last2 = s.sql("SELECT * FROM scores ORDER BY id DESC LIMIT 2")
    print(last2.to_arrow().to_pylist())

# pandas-shaped: sort first, then head(n) or tail(n).
df = komira.read_csv("scores.csv").sort_values("id")
print(df.head(2).materialize().to_arrow().to_pylist())
print(df.tail(2).materialize().to_arrow().to_pylist())

# polars-shaped: the same verbs on a lazy frame.
lf = pl.scan_csv("scores.csv").sort("score", descending=True)
print(lf.head(3).collect().to_arrow().to_pylist())
