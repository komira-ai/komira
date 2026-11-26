# How do I find (not drop) duplicate rows?

Group by the columns that define a duplicate and keep groups with `count(*) > 1`, or put a window count on every row and filter on it; the pandas-shaped and polars-shaped frames do the same with a grouped count.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

Path("people.csv").write_text(
    "id,name,email\n"
    "1,Ana,ana@example.com\n"
    "2,Bo,bo@example.com\n"
    "3,Ana B,ana@example.com\n"
    "4,Cy,cy@example.com\n"
    "5,Bo,bo@example.com\n"
    "6,Bo,bo@example.com\n"
)

# SQL: group by the columns that define a duplicate and keep groups seen twice or more.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    keys = s.sql(
        "SELECT email, count(*) AS n FROM people"
        " GROUP BY email HAVING count(*) > 1 ORDER BY email"
    )
    print(keys.to_arrow().to_pylist())

    # A window count keeps every row of each duplicated group, whole.
    rows = s.sql(
        "SELECT id, name, email FROM"
        " (SELECT id, name, email, count(*) OVER (PARTITION BY email) AS n FROM people)"
        " WHERE n > 1 ORDER BY id"
    )
    print(rows.to_arrow().to_pylist())

    # Only the extra copies: number the rows in each group and keep the later ones.
    extra = s.sql(
        "SELECT id, name, email FROM"
        " (SELECT id, name, email,"
        "  row_number() OVER (PARTITION BY name, email ORDER BY id) AS rn FROM people)"
        " WHERE rn > 1 ORDER BY id"
    )
    print(extra.to_arrow().to_pylist())

# pandas-shaped: count each row's group, then keep rows whose group has more than one.
df = komira.read_csv("people.csv")
dups = df[df.groupby("email")["id"].transform("count") > 1]
print(dups.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: a window count over the key.
lf = pl.scan_csv("people.csv")
print(lf.filter(pl.len().over("email") > 1).sort("id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'email': 'ana@example.com', 'n': 2}, {'email': 'bo@example.com', 'n': 3}]
[{'id': 1, 'name': 'Ana', 'email': 'ana@example.com'}, {'id': 2, 'name': 'Bo', 'email': 'bo@example.com'}, {'id': 3, 'name': 'Ana B', 'email': 'ana@example.com'}, {'id': 5, 'name': 'Bo', 'email': 'bo@example.com'}, {'id': 6, 'name': 'Bo', 'email': 'bo@example.com'}]
[{'id': 5, 'name': 'Bo', 'email': 'bo@example.com'}, {'id': 6, 'name': 'Bo', 'email': 'bo@example.com'}]
[{'id': 1, 'name': 'Ana', 'email': 'ana@example.com'}, {'id': 2, 'name': 'Bo', 'email': 'bo@example.com'}, {'id': 3, 'name': 'Ana B', 'email': 'ana@example.com'}, {'id': 5, 'name': 'Bo', 'email': 'bo@example.com'}, {'id': 6, 'name': 'Bo', 'email': 'bo@example.com'}]
[{'id': 1, 'name': 'Ana', 'email': 'ana@example.com'}, {'id': 2, 'name': 'Bo', 'email': 'bo@example.com'}, {'id': 3, 'name': 'Ana B', 'email': 'ana@example.com'}, {'id': 5, 'name': 'Bo', 'email': 'bo@example.com'}, {'id': 6, 'name': 'Bo', 'email': 'bo@example.com'}]
```

## Notes

- The first query lists each duplicated key with how many rows share it. The second keeps every row of a duplicated group; the third numbers the rows of a group with `row_number()` and keeps only the later copies, so the first row of each group is not reported.
- Name the columns of the key in `GROUP BY` / `PARTITION BY`: `email` alone finds rows 1 and 3 as duplicates, while `name, email` together does not.
- The pandas-shaped frame has no `duplicated()` yet, so the example counts each row's group with `df.groupby("email")["id"].transform("count")` and filters on it. The polars-shaped frame has no `is_duplicated()`, so it uses `pl.len().over("email")`.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values` / `sort`.

## Related

- How do I remove duplicate rows? (rank 13, works; no page yet)
- How do I count how many times each value appears? (rank 9, works; no page yet)
- [How do I validate data: nulls, uniqueness, ranges?](../59-validate-data-nulls-uniqueness-ranges/page.md) (rank 59, works)
- [How do I standardize inconsistent category spellings?](../58-standardize-inconsistent-category-spellings/page.md) (rank 58, works)
