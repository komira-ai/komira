# How do I lowercase, trim and replace text in a column?

Use `lower`, `trim` and `replace` in SQL, `.str.lower()`, `.str.strip()` and `.str.replace()` on the pandas-shaped frame, and `str.to_lowercase()`, `str.strip_chars()` and `str.replace()` on the polars-shaped frame.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

# Row 4 starts with a tab and ends with a non-breaking space.
Path("people.csv").write_text(
    "id,name\n"
    '1,"  Ana SMITH "\n'
    "2,bo-JONES\n"
    '3," cy   LEE"\n'
    '4,"\tDi-RAY\xa0"\n'
)

# SQL: lower, trim and replace compose as functions. trim(name) removes
# spaces only, so the tab and the non-breaking space of row 4 stay.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    clean = s.sql(
        "SELECT id, replace(lower(trim(name)), '-', ' ') AS name"
        " FROM people ORDER BY id"
    )
    print(clean.to_arrow().to_pylist())

# pandas-shaped: .str.strip() removes all whitespace, as Python's str.strip()
# does: spaces, the tab and the non-breaking space.
df = komira.read_csv("people.csv")
df["name"] = df["name"].str.strip().str.lower().str.replace("-", " ", regex=False)
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: str.strip_chars(), then str.replace() of the first match.
lf = kpl.scan_csv("people.csv").with_columns(kpl.col("name").str.strip_chars().str.to_lowercase())
lf = lf.with_columns(kpl.col("name").str.replace("-", " ", literal=True))
print(lf.sort("id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'ana smith'}, {'id': 2, 'name': 'bo jones'}, {'id': 3, 'name': 'cy   lee'}, {'id': 4, 'name': '\tdi ray\xa0'}]
[{'id': 1, 'name': 'ana smith'}, {'id': 2, 'name': 'bo jones'}, {'id': 3, 'name': 'cy   lee'}, {'id': 4, 'name': 'di ray'}]
[{'id': 1, 'name': 'ana smith'}, {'id': 2, 'name': 'bo jones'}, {'id': 3, 'name': 'cy   lee'}, {'id': 4, 'name': 'di ray'}]
```

## Notes

- SQL `trim(name)` removes spaces only, as DuckDB's does; `trim(name, chars)`, `ltrim(name, chars)` and `rtrim(name, chars)` remove each character of `chars`. pandas `.str.strip()`, `.str.lstrip()` and `.str.rstrip()` with no argument remove all whitespace, as Python's `str.strip()` does (a tab, a newline, a non-breaking space); `to_strip="xy"` removes any of the characters `x` and `y`, a set and not a prefix.
- polars `str.strip_chars()` removes the Unicode whitespace, as polars does; `str.strip_chars_start()` and `str.strip_chars_end()` trim one side.
- `.str.replace()` replaces the text itself by default (`regex=False`), as pandas does; `regex=True` takes a regular expression. `n=` (first n occurrences) and a function as the replacement are refused.
- polars `str.replace()` changes the first match and `str.replace_all()` every match; the pattern is a regular expression unless `literal=True`, and `$1` in the value is the first group. A regular expression over a computed column is refused today, so the example strips in one `with_columns` and replaces in the next.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`.

## Related

- [How do I filter rows where a text column contains a substring?](../41-filter-rows-text-column-contains-substring/page.md) (rank 41, works)
- [How do I concatenate string columns?](../43-concatenate-string-columns/page.md) (rank 43, partial)
- [How do I split a string column into several columns?](../44-split-string-column-columns/page.md) (rank 44, partial)
