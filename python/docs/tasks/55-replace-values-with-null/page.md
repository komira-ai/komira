# How do I replace specific values such as 'N/A' with null?

On a polars-shaped frame, `when(column.is_in([...])).then(None).otherwise(column)` turns the placeholder spellings into null; in SQL, `NULLIF(column, value)` does it for a numeric column.

<!-- include example.py -->
```python
from pathlib import Path

import komira
from komira import pl

Path("contacts.csv").write_text(
    "name,city,phone,score\n"
    "Ana,Oslo,555-0101,8\n"
    "Bo,N/A,n/a,-1\n"
    "Cy,Lima,555-0103,6\n"
    "Di,N/A,-,-1\n"
)

# polars-shaped: when(value is a placeholder) then None, otherwise keep it.
# is_in takes a list of spellings, so several placeholders are one condition.
placeholders = ["N/A", "n/a", "-"]
clean = (
    pl.scan_csv("contacts.csv")
    .with_columns(
        *[
            pl.when(pl.col(c).is_in(placeholders)).then(None).otherwise(pl.col(c)).alias(c)
            for c in ["city", "phone"]
        ]
    )
    .sort("name")
    .collect()
)
print(clean.to_arrow().to_pylist())

# SQL: NULLIF(value, sentinel) is NULL where the value equals the sentinel.
# It takes a numeric column; a text column goes through the frame above.
with komira.Session() as s:
    s.register_csv("contacts", "contacts.csv")
    scores = s.sql("SELECT name, NULLIF(score, -1) AS score FROM contacts ORDER BY name")
    print(scores.to_arrow().to_pylist())
    mean = s.sql("SELECT avg(NULLIF(score, -1)) AS mean FROM contacts").to_arrow().to_pylist()
    print(mean)
```

Output:

<!-- include expected_output.txt -->
```text
[{'name': 'Ana', 'city': 'Oslo', 'phone': '555-0101', 'score': 8}, {'name': 'Bo', 'city': None, 'phone': None, 'score': -1}, {'name': 'Cy', 'city': 'Lima', 'phone': '555-0103', 'score': 6}, {'name': 'Di', 'city': None, 'phone': None, 'score': -1}]
[{'name': 'Ana', 'score': 8}, {'name': 'Bo', 'score': None}, {'name': 'Cy', 'score': 6}, {'name': 'Di', 'score': None}]
[{'mean': 7.0}]
```

## Notes

- `is_in` takes the whole list of placeholder spellings at once, and the same `when` expression runs over each column in a loop. Matching is exact, so `N/A` and `n/a` are listed separately.
- After the replacement the values are real nulls: `avg(NULLIF(score, -1))` skips them.
- In SQL, `NULLIF` and `CASE ... THEN NULL` over a text column are refused today with a named error, so only a numeric column can be cleaned in SQL; the text columns use the polars-shaped form: komira-ai/komira#2401.
- The pandas-shaped frame has no `replace` yet, and `read_csv` takes no `na_values=`: komira-ai/komira#2401. `probe_replace.py` beside this page tries `df.replace([...], None)` and must fail with the line in `probe_replace.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it. It has no `where` or `mask` either: komira-ai/komira#2370.

## Related

- How do I find and fill missing values? (rank 6, works; no page yet)
- [How do I convert a column to numbers, turning bad values into null?](../60-convert-column-to-numbers/page.md) (rank 60, partial)
- [How do I validate data: nulls, uniqueness, ranges?](../59-validate-data-nulls-uniqueness-ranges/page.md) (rank 59, works)
- How do I add a column with if/else (case when) logic? (rank 30, works; no page yet)
