# How do I compare two datasets and show the differences?

FULL JOIN the two tables on their key in SQL and keep the rows with no partner or with different values; the pandas-shaped form is `isin` for rows only in one side and an inner `merge` for changed values.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# Two versions of a small stock table, keyed by id.
Path("stock_old.csv").write_text("id,qty\n1,10\n2,5\n3,7\n")
Path("stock_new.csv").write_text("id,qty\n2,5\n3,9\n4,3\n")

# SQL: a FULL JOIN on the key lines the versions up. A row with no partner
# was removed or added; a row with two different values changed.
with komira.Session() as s:
    s.register_csv("stock_old", "stock_old.csv")
    s.register_csv("stock_new", "stock_new.csv")
    diff = s.sql(
        "SELECT coalesce(o.id, n.id) AS key_id,"
        " CASE WHEN n.id IS NULL THEN 'removed'"
        " WHEN o.id IS NULL THEN 'added' ELSE 'changed' END AS kind,"
        " o.qty AS old_qty, n.qty AS new_qty"
        " FROM stock_old AS o FULL JOIN stock_new AS n ON o.id = n.id"
        " WHERE o.id IS NULL OR n.id IS NULL OR o.qty <> n.qty"
        " ORDER BY key_id"
    )
    for row in diff.to_arrow().to_pylist():
        print(row)

# pandas-shaped: the same three questions, one frame each.
old = komira.read_csv("stock_old.csv")
new = komira.read_csv("stock_new.csv")
removed = old[~old["id"].isin(new["id"])]
added = new[~new["id"].isin(old["id"])]
both = old.merge(new, on="id", suffixes=("_old", "_new"))
changed = both[both["qty_old"] != both["qty_new"]]
for frame in (removed, added, changed):
    print(frame.sort_values("id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'key_id': 1, 'kind': 'removed', 'old_qty': 10, 'new_qty': None}
{'key_id': 3, 'kind': 'changed', 'old_qty': 7, 'new_qty': 9}
{'key_id': 4, 'kind': 'added', 'old_qty': None, 'new_qty': 3}
[{'id': 1, 'qty': 10}]
[{'id': 4, 'qty': 3}]
[{'id': 3, 'qty_old': 7, 'qty_new': 9}]
```

## Notes

- The SQL form is one query: `coalesce` takes the key from whichever side has it, and `CASE` names the kind of difference. `<>` is NULL, not true, when either value is NULL, so a row whose value is NULL on one side only is not reported as changed. `IS DISTINCT FROM` is not supported.
- The pandas-shaped `!=` follows SQL as well: a NULL compared with anything is not a difference, where pandas would report it.
- `merge(how="outer")` works and takes the key of the side that has one, but `merge(indicator=True)` is refused (`UnsupportedOperation`), so the column saying which side a row came from is not available: use the SQL `CASE`, or `isin` as above.
- `DataFrame.compare` and `DataFrame.equals` are not defined; the merge on the key and a column comparison replace them.
- `EXCEPT` also works in SQL for whole rows (`SELECT * FROM a EXCEPT SELECT * FROM b`, both ways), and returns distinct rows; `EXCEPT ALL` is refused (komira-ai/komira#1229).
- Results have no row order unless sorted, so the example sorts every answer.

## Related

- How do I find rows in A that are not in B (anti-join)? (rank 69, works)
- How do I join two tables on a key? (rank 10, works; no page yet)
- How do I left join and keep unmatched rows? (rank 36, works; no page yet)
- How do I join on multiple columns? (rank 73, works; no page yet)
