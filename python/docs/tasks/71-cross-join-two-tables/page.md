# How do I cross join two tables?

Use `CROSS JOIN` in SQL (or a comma between the tables), or `merge(how="cross")` on a pandas-shaped frame: every row of one table is paired with every row of the other.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("sizes.csv").write_text("size\nS\nM\nL\n")
Path("colors.csv").write_text("color,code\nred,1\nblue,2\n")

# SQL: CROSS JOIN pairs every row of one table with every row of the other.
with komira.Session() as s:
    s.register_csv("sizes", "sizes.csv")
    s.register_csv("colors", "colors.csv")
    pairs = s.sql(
        "SELECT size, color FROM sizes CROSS JOIN colors ORDER BY size, color"
    )
    print(pairs.to_arrow().to_pylist())

    # A comma between the tables, with no join condition, is the same join.
    n = s.sql("SELECT count(*) AS n FROM sizes, colors")
    print(n.to_arrow().to_pylist())

# pandas-shaped: merge with how="cross" takes no keys.
sizes = komira.read_csv("sizes.csv")
colors = komira.read_csv("colors.csv")
both = sizes.merge(colors, how="cross").sort_values(["size", "color"])
print(both.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'size': 'L', 'color': 'blue'}, {'size': 'L', 'color': 'red'}, {'size': 'M', 'color': 'blue'}, {'size': 'M', 'color': 'red'}, {'size': 'S', 'color': 'blue'}, {'size': 'S', 'color': 'red'}]
[{'n': 6}]
[{'size': 'L', 'color': 'blue', 'code': 2}, {'size': 'L', 'color': 'red', 'code': 1}, {'size': 'M', 'color': 'blue', 'code': 2}, {'size': 'M', 'color': 'red', 'code': 1}, {'size': 'S', 'color': 'blue', 'code': 2}, {'size': 'S', 'color': 'red', 'code': 1}]
```

## Notes

- The result has as many rows as the two tables multiplied: 3 sizes by 2 colors is 6 rows. A cross join of two large tables is very large, so filter first or ask whether a join on a key is what you want.
- A cross join takes no keys: `merge(how="cross")` refuses `on`, `left_on` and `right_on`.
- When both frames have a column of one name, `merge(how="cross")` keeps both and suffixes them `_x` and `_y`, as pandas does; the example uses distinct names so none is renamed.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- How do I match each row to the nearest earlier timestamp (as-of join)? (rank 72, gap; no page yet)
- How do I join on multiple columns? (rank 73, works)
- How do I join many tables in one query? (rank 74, works)
- How do I join where a value falls between two bounds? (rank 75, works)
