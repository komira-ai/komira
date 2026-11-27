# How do I lowercase, trim and replace text in a column?

Use `lower`, `trim` and `replace` in SQL; the pandas-shaped frame has `.str.lower()` and `.str.replace()` but not `.str.strip()` yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("people.csv").write_text(
    "id,name\n"
    '1,"  Ana SMITH "\n'
    "2,bo-JONES\n"
    '3," cy   LEE"\n'
)

# SQL: lower, trim and replace compose as functions.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    clean = s.sql(
        "SELECT id, replace(lower(trim(name)), '-', ' ') AS name"
        " FROM people ORDER BY id"
    )
    print(clean.to_arrow().to_pylist())

# pandas-shaped: .str.lower() and .str.replace() (trimming is not here yet).
df = komira.read_csv("people.csv")
df["name"] = df["name"].str.lower().str.replace("-", " ", regex=False)
print(df.sort_values("id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'ana smith'}, {'id': 2, 'name': 'bo jones'}, {'id': 3, 'name': 'cy   lee'}]
[{'id': 1, 'name': '  ana smith '}, {'id': 2, 'name': 'bo jones'}, {'id': 3, 'name': ' cy   lee'}]
```

## Notes

- SQL `trim` removes spaces only. pandas `.str.strip()` removes all whitespace (tabs, newlines), so komira refuses it by name instead of trimming differently: `.str.strip()`, `.str.lstrip()` and `.str.rstrip()` raise an error on the pandas-shaped frame today (komira-ai/komira#2371). `probe_str_strip.py` beside this page tries `.str.strip()` and must fail with the line in `probe_str_strip.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- `.str.replace()` replaces the text itself by default (`regex=False`), as pandas does; `regex=True` takes a regular expression. `n=` (first n occurrences) and a function as the replacement are refused.
- The polars-shaped frame has `str.to_lowercase()` but no trim or replace yet (komira-ai/komira#2371).
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I filter rows where a text column contains a substring?](../41-filter-rows-text-column-contains-substring/page.md) (rank 41, works)
- [How do I concatenate string columns?](../43-concatenate-string-columns/page.md) (rank 43, partial)
- [How do I split a string column into several columns?](../44-split-string-column-columns/page.md) (rank 44, partial)
