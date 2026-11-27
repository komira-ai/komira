# How do I replace specific values such as 'N/A' with null?

On the pandas-shaped frame, `df.replace([...], None)` turns the placeholder spellings into null, and `s.replace(value, None)` does one column; on a polars-shaped frame, `when(column.is_in([...])).then(None).otherwise(column)` does it; in SQL, `NULLIF(column, value)` does it for a numeric column.

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

# pandas-shaped: replace(list, None) turns every listed spelling into null in
# each column whose type can hold it, and a dict names a column's own values.
df = komira.read_csv("contacts.csv")
clean = df.replace(["N/A", "n/a", "-"], None).replace({"score": -1}, None)
print(clean.sort_values("name").materialize().to_arrow().to_pylist())
print(clean[["score"]].mean().materialize().to_arrow().to_pylist())
# s.replace does one column.
city = df.assign(city=df["city"].replace("N/A", None))[["name", "city"]]
print(city.sort_values("name").materialize().to_arrow().to_pylist())

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
[{'name': 'Ana', 'city': 'Oslo', 'phone': '555-0101', 'score': 8}, {'name': 'Bo', 'city': None, 'phone': None, 'score': None}, {'name': 'Cy', 'city': 'Lima', 'phone': '555-0103', 'score': 6}, {'name': 'Di', 'city': None, 'phone': None, 'score': None}]
[{'score': 7.0}]
[{'name': 'Ana', 'city': 'Oslo'}, {'name': 'Bo', 'city': None}, {'name': 'Cy', 'city': 'Lima'}, {'name': 'Di', 'city': None}]
[{'name': 'Ana', 'score': 8}, {'name': 'Bo', 'score': None}, {'name': 'Cy', 'score': 6}, {'name': 'Di', 'score': None}]
[{'mean': 7.0}]
```

## Notes

- `df.replace(list, None)` changes every column whose type can hold a listed value and leaves the others as they are, with their types: the text spellings meet only the text columns. `df.replace({"score": -1}, None)` names a column's own values; `{old: new}` and `{column: {old: new}}` with no value map old to new. The forms and what matches are pandas 3's; a replacement that would change a column's type (text into a number column) is refused by name.
- `is_in` takes the whole list of placeholder spellings at once, and the same `when` expression runs over each column in a loop. Matching is exact in every form, so `N/A` and `n/a` are listed separately.
- After the replacement the values are real nulls: the frame's `mean()` and `avg(NULLIF(score, -1))` skip them.
- In SQL, `NULLIF` and `CASE ... THEN NULL` over a text column are refused today with a named error, so only a numeric column can be cleaned in SQL; the text columns use the polars-shaped form: komira-ai/komira#2401.
- `read_csv` takes no `na_values=`, so the spellings are read as text and replaced after: komira-ai/komira#2401. The pandas-shaped frame has no `where` or `mask`: komira-ai/komira#2370.

## Related

- How do I find and fill missing values? (rank 6, works; no page yet)
- [How do I convert a column to numbers, turning bad values into null?](../60-convert-column-to-numbers/page.md) (rank 60, partial)
- [How do I validate data: nulls, uniqueness, ranges?](../59-validate-data-nulls-uniqueness-ranges/page.md) (rank 59, works)
- How do I add a column with if/else (case when) logic? (rank 30, works; no page yet)
