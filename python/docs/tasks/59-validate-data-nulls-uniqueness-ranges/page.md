# How do I validate data: nulls, uniqueness, ranges?

Write each rule as a SQL query that counts the rows breaking it, then list those rows.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("people.csv").write_text(
    "id,name,age\n1,Ana,34\n2,Bo,\n3,Cy,29\n3,Di,150\n5,,41\n6,Ed,-2\n"
)

# One query per rule; each returns the number of rows that break it.
checks = {
    "name is null": "SELECT count(*) AS bad FROM people WHERE name IS NULL",
    "age is null": "SELECT count(*) AS bad FROM people WHERE age IS NULL",
    "age outside 0..120": "SELECT count(*) AS bad FROM people WHERE age < 0 OR age > 120",
    "id repeated": (
        "SELECT count(*) AS bad FROM (SELECT id FROM people GROUP BY id HAVING count(*) > 1) AS d"
    ),
}

with komira.Session() as s:
    s.register_csv("people", "people.csv")
    for rule, sql in checks.items():
        bad = s.sql(sql).to_arrow().to_pylist()[0]["bad"]
        print(f"{'FAIL' if bad else 'ok  '} {rule}: {bad}")
    # The offending rows, not just their count.
    for row in s.sql(
        "SELECT id, name, age FROM people"
        " WHERE name IS NULL OR age IS NULL OR age < 0 OR age > 120 ORDER BY id, name"
    ).to_arrow().to_pylist():
        print(row)
```

Output:

<!-- include expected_output.txt -->
```text
FAIL name is null: 1
FAIL age is null: 1
FAIL age outside 0..120: 2
FAIL id repeated: 1
{'id': 2, 'name': 'Bo', 'age': None}
{'id': 3, 'name': 'Di', 'age': 150}
{'id': 5, 'name': None, 'age': 41}
{'id': 6, 'name': 'Ed', 'age': -2}
```

## Notes

- Each check is a plain `count(*)` with a `WHERE` (nulls, ranges) or a `GROUP BY ... HAVING count(*) > 1` (uniqueness); a count of 0 means the rule holds. A comparison such as `age < 0` is never true for a NULL age, so nulls are counted by their own rule.
- The id 3 appears twice, so the uniqueness rule counts one repeated id; the final query lists the rows that break the null and range rules, ordered by `id, name`.
- To stop a pipeline on a failure, test the counts in Python (`assert bad == 0`) or exit when any rule prints `FAIL`.
- The pandas-shaped frame can filter by a range (`df[(df["age"] < 0) | (df["age"] > 120)]`), but has no `isna()` (komira-ai/komira#2362), so the rules are written in SQL; `df.duplicated("id", keep=False)` marks the rows of a repeated id.

## Related

- [How do I find (not drop) duplicate rows?](../57-find-duplicate-rows/page.md) (rank 57, works)
- How do I find and fill missing values? (rank 6, works; no page yet)
- [How do I convert a column to numbers, turning bad values into null?](../60-convert-column-to-numbers/page.md) (rank 60, partial)
- [How do I detect outliers?](../56-detect-outliers/page.md) (rank 56, partial)
