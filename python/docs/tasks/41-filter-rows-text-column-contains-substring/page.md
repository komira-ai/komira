# How do I filter rows where a text column contains a substring?

Use `WHERE name LIKE '%text%'` (or `contains(name, 'text')`) in SQL, or index a pandas-shaped frame with `df["name"].str.contains("text", regex=False)`.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("products.csv").write_text(
    "id,name\n"
    "1,Red Widget\n"
    "2,blue widget\n"
    "3,Gadget (large)\n"
    "4,Widget Pro\n"
    "5,Gizmo\n"
)

# SQL: LIKE matches a pattern (% is any text); contains() matches the text itself.
with komira.Session() as s:
    s.register_csv("products", "products.csv")
    like = s.sql("SELECT id FROM products WHERE name LIKE '%Widget%' ORDER BY id")
    print(like.to_arrow().to_pylist())

    literal = s.sql("SELECT id FROM products WHERE contains(name, '(large)') ORDER BY id")
    print(literal.to_arrow().to_pylist())

    # Case-insensitive: ILIKE, or lower() on both sides.
    ci = s.sql("SELECT id FROM products WHERE name ILIKE '%widget%' ORDER BY id")
    print(ci.to_arrow().to_pylist())

    starts = s.sql("SELECT id FROM products WHERE starts_with(name, 'Widget') ORDER BY id")
    print(starts.to_arrow().to_pylist())

# pandas-shaped: regex=False searches for the text, not a regular expression.
df = komira.read_csv("products.csv")
hit = df[df["name"].str.contains("(large)", regex=False)]
print(hit.materialize().to_arrow().to_pylist())

ci = df[df["name"].str.contains("widget", case=False)]
print(ci.sort_values("id").materialize().to_arrow().to_pylist())

starts = df[df["name"].str.startswith("Widget")]
print(starts.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1}, {'id': 4}]
[{'id': 3}]
[{'id': 1}, {'id': 2}, {'id': 4}]
[{'id': 4}]
[{'id': 3, 'name': 'Gadget (large)'}]
[{'id': 1, 'name': 'Red Widget'}, {'id': 2, 'name': 'blue widget'}, {'id': 4, 'name': 'Widget Pro'}]
[{'id': 4, 'name': 'Widget Pro'}]
```

## Notes

- In `LIKE`, `%` matches any run of text and `_` one character; `contains(name, 'text')` and `starts_with(name, 'text')` take the text literally, so `(` and `.` need no escaping.
- On the pandas-shaped frame `str.contains` treats the pattern as a regular expression unless you pass `regex=False`, as in pandas. Pass `regex=False` for a plain substring.
- `case=False` works with the regular-expression form. Combining `case=False` with `regex=False` is refused with `UnsupportedOperation`: escape the text with `re.escape()` and use `regex=True, case=False`, or use `ILIKE` in SQL.
- `strpos()`, `position(... IN ...)` and a `LIKE` with an `ESCAPE` character are refused today; use `contains()` for a text that holds `%` or `_`.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I filter rows where a value is in a list?](../29-filter-rows-value-list/page.md) (rank 29, works)
- [How do I extract part of a string with a regex?](../40-extract-part-string-regex/page.md) (rank 40, works)
- [How do I lowercase, trim and replace text in a column?](../42-lowercase-trim-replace-text-column/page.md) (rank 42, partial)
