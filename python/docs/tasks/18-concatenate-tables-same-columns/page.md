# How do I concatenate (stack) tables with the same columns?

Use `UNION ALL` in SQL, `komira.concat([...])` on pandas-shaped frames, or `komira.pl.concat([...])` on polars-shaped frames; each puts the rows of one table after the rows of the other.

<!-- include example.py -->
```python
from pathlib import Path

import komira
from komira import pl

# Two months of orders, one file each, with the same columns.
Path("jan.csv").write_text("id,name,amt\n1,Ana,9.5\n2,Bo,7.0\n")
Path("feb.csv").write_text("id,name,amt\n3,Cy,4.25\n4,Di,\n")

# SQL: UNION ALL stacks the rows and keeps duplicates; UNION drops them.
with komira.Session() as s:
    s.register_csv("jan", "jan.csv")
    s.register_csv("feb", "feb.csv")
    stacked = s.sql("SELECT * FROM jan UNION ALL SELECT * FROM feb ORDER BY id")
    print(stacked.to_arrow().to_pylist())
    # Tag each row with the table it came from.
    tagged = s.sql(
        "SELECT 'jan' AS month, id, name, amt FROM jan"
        " UNION ALL SELECT 'feb', id, name, amt FROM feb ORDER BY id"
    )
    print(tagged.to_arrow().to_pylist())

# pandas-shaped: komira.concat takes a list of frames.
jan = komira.read_csv("jan.csv")
feb = komira.read_csv("feb.csv")
both = komira.concat([jan, feb])
print(both.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: pl.concat stacks LazyFrames.
lazy = pl.concat([pl.scan_csv("jan.csv"), pl.scan_csv("feb.csv")])
print(lazy.sort("id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'Ana', 'amt': 9.5}, {'id': 2, 'name': 'Bo', 'amt': 7.0}, {'id': 3, 'name': 'Cy', 'amt': 4.25}, {'id': 4, 'name': 'Di', 'amt': None}]
[{'month': 'jan', 'id': 1, 'name': 'Ana', 'amt': 9.5}, {'month': 'jan', 'id': 2, 'name': 'Bo', 'amt': 7.0}, {'month': 'feb', 'id': 3, 'name': 'Cy', 'amt': 4.25}, {'month': 'feb', 'id': 4, 'name': 'Di', 'amt': None}]
[{'id': 1, 'name': 'Ana', 'amt': 9.5}, {'id': 2, 'name': 'Bo', 'amt': 7.0}, {'id': 3, 'name': 'Cy', 'amt': 4.25}, {'id': 4, 'name': 'Di', 'amt': None}]
[{'id': 1, 'name': 'Ana', 'amt': 9.5}, {'id': 2, 'name': 'Bo', 'amt': 7.0}, {'id': 3, 'name': 'Cy', 'amt': 4.25}, {'id': 4, 'name': 'Di', 'amt': None}]
```

## Notes

- `UNION ALL` keeps every row; `UNION` drops duplicate rows. `INTERSECT` and `EXCEPT` work too. Put the column list in the same order in every `SELECT`: the columns of a set operation match by position, not by name.
- DuckDB's `UNION ALL BY NAME` (match columns by name) is not parsed: it fails with a syntax error. Name the columns in the same order in each `SELECT` instead.
- A `SELECT` that mixes `*` with other items, such as `SELECT 'jan', * FROM jan`, is refused; list the columns, as the tagged query above does.
- `komira.concat` and `komira.pl.concat` need frames with the same columns and the same types. A frame with the same columns in another order is reordered by `komira.concat`; `komira.pl.concat` refuses it, so select the columns in one order first. Neither fills a missing column with null: that is refused with a message naming the column, where pandas would fill it with NaN.
- A frame has no row index, so `ignore_index`, `keys`, `axis=1` and `verify_integrity` of pandas have no use here (`ignore_index` is accepted and does nothing; the others are refused by name). The rows of a concatenation come back in no promised order: sort before printing, as the example does.
- Polars' `how="diagonal"` and `DataFrame.vstack`, and the removed pandas `DataFrame.append`, are not offered.
- To stack many files with one name pattern, see the related task below.
- `komira.concat` is newer than the PyPI release 0.1.1623.

## Related

- [How do I read many files matching a pattern into one table?](../19-read-many-files-matching-pattern-table/page.md) (rank 19, partial)
- [How do I remove duplicate rows?](../13-remove-duplicate-rows/page.md) (rank 13, partial)
- [How do I rename columns?](../16-rename-columns/page.md) (rank 16, works)
- [How do I join two tables on a key?](../10-join-two-tables-on-key/page.md) (rank 10, works)
