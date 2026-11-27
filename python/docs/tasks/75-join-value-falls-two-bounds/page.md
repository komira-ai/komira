# How do I join where a value falls between two bounds?

Put the range in the join's `ON`: `JOIN bands AS b ON r.reading BETWEEN b.lo AND b.hi` pairs each row with the row whose bounds contain its value.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("readings.csv").write_text("id,reading\n1,5\n2,10\n3,19\n4,25\n5,40\n")
Path("bands.csv").write_text("band,lo,hi\nlow,0,9\nmid,10,19\nhigh,20,29\n")

with komira.Session() as s:
    s.register_csv("readings", "readings.csv")
    s.register_csv("bands", "bands.csv")

    # A range join: ON takes a condition between the two tables, not only
    # an equality. BETWEEN includes both bounds.
    banded = s.sql(
        "SELECT r.id AS id, r.reading AS reading, b.band AS band"
        " FROM readings AS r JOIN bands AS b"
        " ON r.reading BETWEEN b.lo AND b.hi ORDER BY r.id"
    )
    print(banded.to_arrow().to_pylist())

    # The same join with two comparisons: here the upper bound is excluded.
    half_open = s.sql(
        "SELECT r.id AS id, b.band AS band"
        " FROM readings AS r JOIN bands AS b"
        " ON r.reading >= b.lo AND r.reading < b.hi ORDER BY r.id"
    )
    print(half_open.to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'reading': 5, 'band': 'low'}, {'id': 2, 'reading': 10, 'band': 'mid'}, {'id': 3, 'reading': 19, 'band': 'mid'}, {'id': 4, 'reading': 25, 'band': 'high'}]
[{'id': 1, 'band': 'low'}, {'id': 2, 'band': 'mid'}, {'id': 4, 'band': 'high'}]
```

## Notes

- `BETWEEN lo AND hi` keeps both ends, so reading 19 matches the `mid` band (10 to 19). Write the two comparisons to exclude an end, as the second query does.
- A reading that falls in no band (id 5) has no match, so an inner join drops it. If bands overlap, a reading matches every band that contains it and appears once for each.
- An inner `JOIN ... ON` with a range is bound as a cross join filtered by the condition, so it compares every reading with every band: fine for a small lookup table such as bands, slow when both sides are large.
- A `LEFT`, `RIGHT` or `FULL` join whose `ON` has no equality (`ON r.reading BETWEEN b.lo AND b.hi`) is refused by name today. Add an equality on a shared key if there is one, or use the inner join.
- On a pandas-shaped frame there is no range `merge`: pair the rows with `merge(how="cross")` and filter the result by comparing the columns, which is the same work as the SQL above.

## Related

- How do I cross join two tables? (rank 71, works)
- How do I match each row to the nearest earlier timestamp (as-of join)? (rank 72, gap; no page yet)
- How do I join on multiple columns? (rank 73, works)
- How do I join many tables in one query? (rank 74, works)
