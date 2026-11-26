# How do I bucket numeric values into bins?

Label each range with `CASE WHEN` (or `when(...).then(...).otherwise(...)` on a polars-shaped frame), or subtract the remainder to get bins of equal width.

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'grade': 'A'}, {'id': 2, 'grade': 'B'}, {'id': 3, 'grade': 'C'}, {'id': 4, 'grade': 'B'}, {'id': 5, 'grade': 'C'}, {'id': 6, 'grade': 'B'}, {'id': 7, 'grade': 'A'}]
[{'lo': 40, 'n': 2}, {'lo': 60, 'n': 2}, {'lo': 80, 'n': 2}, {'lo': 100, 'n': 1}]
['A', 'B', 'C', 'B', 'C', 'B', 'A']
```

## Notes

- `CASE WHEN` tests its branches in order and takes the first that holds, so write the highest range first. A row that matches none takes the `ELSE` value, or NULL without an `ELSE`; a NULL score matches no `>=` test.
- `score - score % 20` keeps integers integer. `/` on integers answers a double in SQL, so `floor(score / 20) * 20` gives `80.0`, not `80`.
- The polars-shaped `otherwise` is required. Wrap the labels in `pl.lit`: polars reads a bare string in `then` as a column name, so the same code then runs on polars too.
- The pandas-shaped frame has no `komira.cut` (the lookup raises `AttributeError`), no `Series.where` or `case_when`, and no `//` or `%` on a Series. Bin in SQL, or in the polars-shaped skin.
- Sort the counts (`ORDER BY lo`): rows of a `GROUP BY` come back in no promised order.

## Related

- How do I count the rows of a table? (rank 62, works)
- How do I add a new column computed from other columns? (rank 3, works; no page yet)
- How do I detect outliers? (rank 56, partial; no page yet)
- How do I convert a column to numbers, turning bad values into null? (rank 60, works; no page yet)
