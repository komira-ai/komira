from pathlib import Path

import komira
import komira.pl as pl

Path("scores.csv").write_text(
    "id,score\n"
    "1,95\n"
    "2,72\n"
    "3,58\n"
    "4,88\n"
    "5,41\n"
    "6,79\n"
    "7,100\n"
)

with komira.Session() as s:
    s.register_csv("scores", "scores.csv")

    # SQL: CASE WHEN gives each range a label.
    grades = s.sql(
        "SELECT id, CASE WHEN score >= 90 THEN 'A' WHEN score >= 70 THEN 'B' ELSE 'C' END AS grade"
        " FROM scores ORDER BY id"
    )
    print(grades.to_arrow().to_pylist())

    # SQL: bins of equal width, here 20: score minus its remainder is the bin's start.
    widths = s.sql(
        "SELECT lo, count(*) AS n FROM (SELECT score - score % 20 AS lo FROM scores) AS b"
        " GROUP BY lo ORDER BY lo"
    )
    print(widths.to_arrow().to_pylist())

# polars-shaped: when / then / otherwise.
score = pl.col("score")
grade = (
    pl.when(score >= 90).then(pl.lit("A"))
    .when(score >= 70).then(pl.lit("B"))
    .otherwise(pl.lit("C"))
)
lf = pl.scan_csv("scores.csv").select("id", grade.alias("grade")).sort("id")
print(lf.collect().to_arrow().column("grade").to_pylist())
