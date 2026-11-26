# How do I sort rows by one or more columns?

Name the keys in `ORDER BY`, each with `DESC` where it should run downwards, or call `sort_values` on a pandas-shaped frame or `sort` on a polars-shaped one with a list of columns and a list of directions.

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
{'name': 'Di', 'team': 'blue', 'score': 9}
{'name': 'Bo', 'team': 'blue', 'score': 7}
{'name': 'Flo', 'team': 'blue', 'score': 5}
{'name': 'Ana', 'team': 'red', 'score': 9}
{'name': 'Ed', 'team': 'red', 'score': 7}
{'name': 'Cy', 'team': 'red', 'score': None}
['Cy', 'Ana', 'Di', 'Bo', 'Ed', 'Flo']
['Di', 'Bo', 'Flo', 'Ana', 'Ed', 'Cy']
['Cy', 'Ana', 'Di', 'Bo', 'Ed', 'Flo']
['Di', 'Bo', 'Flo', 'Cy', 'Ana', 'Ed']
['Di', 'Bo', 'Flo', 'Ana', 'Ed', 'Cy']
```

## Notes

- Every key has its own direction: `ORDER BY team, score DESC`, `ascending=[True, False]` in `sort_values`, `descending=[False, True]` in `sort`.
- Rows that tie on every key come out in no promised order, because no sort is stable. Add a column that breaks the ties, as `name` is added above.
- Where NULLs go depends on the skin. SQL and `sort_values` put NULLs last in both directions; `NULLS FIRST` and `na_position="first"` move them to the front. polars puts them first, and `nulls_last=True` moves them to the end. `na_position` applies to every key of the call; `nulls_last` takes one bool for all keys or a list with one per key.
- `sort_values(kind="stable")`, `sort_values(kind="mergesort")` and `sort(maintain_order=True)` are refused, because they ask for a stable sort; `sort_values(inplace=True)` and `sort_values(key=...)` are refused too. Sort by more columns, or assign the sort key as a column first and sort by it.
- `sort_index` is refused, since a komira frame has no index. `sort_values` and `sort` return a new frame; the order holds when the frame runs at `materialize()` or `collect()`.
- A sorted frame keeps its order through `head`, a filter and a column selection that keeps the sort columns, so `sort_values("score", ascending=False).head(3)` gives the three highest scores.

## Related

- [How do I look at the first rows, row count and columns of a dataset?](../5-look-at-first-rows-and-columns/page.md) (rank 5, works)
- How do I take the first or last N rows? (rank 65, works; no page yet)
- How do I get the top N rows per group? (rank 47, works; no page yet)
- How do I rank rows within a group? (rank 49, works; no page yet)
