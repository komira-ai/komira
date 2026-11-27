from pathlib import Path

import komira
import komira.pl as kpl

# Cy has no score: the empty field reads as NULL.
Path("scores.csv").write_text(
    "name,team,score\n"
    "Ana,red,9\n"
    "Bo,blue,7\n"
    "Cy,red,\n"
    "Di,blue,9\n"
    "Ed,red,7\n"
    "Flo,blue,5\n"
)


def names(result):
    return result.to_arrow()["name"].to_pylist()


# SQL: ORDER BY lists the keys, each with its own direction. A NULL sorts
# last in both directions unless the key says NULLS FIRST.
with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    rows = s.sql("SELECT name, team, score FROM scores ORDER BY team, score DESC")
    for row in rows.to_arrow().to_pylist():
        print(row)
    print(names(s.sql("SELECT name, score FROM scores ORDER BY score DESC NULLS FIRST, name")))

# pandas-shaped: one direction per key, and NULLs last unless na_position="first".
df = komira.read_csv("scores.csv")
print(names(df.sort_values(["team", "score"], ascending=[True, False]).materialize()))
print(names(df.sort_values(["score", "name"], ascending=[False, True], na_position="first").materialize()))

# polars-shaped: nulls come first unless nulls_last=True.
lf = kpl.scan_csv("scores.csv")
print(names(lf.sort(["team", "score"], descending=[False, True]).collect()))
print(names(lf.sort(["team", "score"], descending=[False, True], nulls_last=True).collect()))
