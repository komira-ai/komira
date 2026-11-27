# How do I take the first or last N rows?

Sort, then take N: `ORDER BY ... LIMIT n` in SQL, or `sort_values(...).head(n)` / `.tail(n)` on a pandas-shaped frame and `sort(...).head(n)` / `.tail(n)` on a polars-shaped one.

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 2, 'name': 'Bo', 'score': 95}, {'id': 6, 'name': 'Flo', 'score': 91}, {'id': 4, 'name': 'Di', 'score': 88}]
[{'id': 6, 'name': 'Flo', 'score': 91}, {'id': 5, 'name': 'Ed', 'score': 79}]
[{'id': 1, 'name': 'Ana', 'score': 72}, {'id': 2, 'name': 'Bo', 'score': 95}]
[{'id': 5, 'name': 'Ed', 'score': 79}, {'id': 6, 'name': 'Flo', 'score': 91}]
[{'id': 2, 'name': 'Bo', 'score': 95}, {'id': 6, 'name': 'Flo', 'score': 91}, {'id': 4, 'name': 'Di', 'score': 88}]
```

## Notes

- A table has no row order of its own, so "first" and "last" mean first and last by a sort. Without a sort, `head(n)` returns some `n` rows, and the example sorts so its output is the same on every run.
- `tail(n)` needs a sorted frame and keeps that sort's order: it is the first `n` rows of the reversed sort, sorted back. On an unsorted frame it is refused, and so is `tail` after `head`: take the tail before the head. In SQL, sort descending and `LIMIT n` (as above), or put that query in a subquery and sort it again to get ascending order.
- A negative count (`head(-2)`, `tail(-2)`) is refused, since it needs the row count: sort and ask for the rows you want.
- Rows that tie on the sort key at the cut come out in no promised order: add a column to break the ties (`sort_values(["score", "id"])`).
- The pandas names `iloc` and `loc` are refused, since a komira frame has no index: use `sort_values(...).head(n)`.
- On the polars-shaped frame, `slice(offset, length)` with an offset, and `tail`, need a sorted frame, and `top_k(k, by=...)` / `bottom_k(k, by=...)` take the largest or smallest `k` rows in no particular order.

## Related

- [How do I sort rows by one or more columns?](../8-sort-rows-by-columns/page.md) (rank 8, works)
- [How do I look at the first rows, row count and columns of a dataset?](../5-look-at-first-rows-and-columns/page.md) (rank 5, works)
- How do I remove duplicate rows? (rank 13, works; no page yet)
