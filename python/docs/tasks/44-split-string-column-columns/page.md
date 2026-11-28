# How do I split a string column into several columns?

Take each part with its own `regexp_extract` in SQL, or its own `.str.extract(..., expand=False)` on the pandas-shaped frame; `.str.split(expand=True)` is not supported yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("people.csv").write_text("id,full_name\n1,Ana Smith\n2,Bo Lee\n3,Cy\n")

# SQL: one regexp_extract per part, each taking one capture group of the
# same pattern. A part the string lacks is ''.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    sql = (
        "SELECT id,"
        " regexp_extract(full_name, '^(\\S+) ?(.*)$', 1) AS first,"
        " regexp_extract(full_name, '^(\\S+) ?(.*)$', 2) AS last"
        " FROM people ORDER BY id"
    )
    for row in s.sql(sql).to_arrow().to_pylist():
        print(row)

# pandas-shaped: str.extract with expand=False gives one part per call.
df = komira.read_csv("people.csv")
name = df["full_name"].str
df = df.assign(
    first=name.extract(r"^(\S+)", expand=False),
    last=name.extract(r"^\S+ ?(.*)$", expand=False),
)
print(df.sort_values("id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'id': 1, 'first': 'Ana', 'last': 'Smith'}
{'id': 2, 'first': 'Bo', 'last': 'Lee'}
{'id': 3, 'first': 'Cy', 'last': ''}
[{'id': 1, 'full_name': 'Ana Smith', 'first': 'Ana', 'last': 'Smith'}, {'id': 2, 'full_name': 'Bo Lee', 'first': 'Bo', 'last': 'Lee'}, {'id': 3, 'full_name': 'Cy', 'first': 'Cy', 'last': ''}]
```

## Notes

- Each part is one regular expression with a capture group, so the number of parts is fixed in the query. A string with fewer parts than the pattern names gives `''` for the missing ones, not NULL.
- `.str.extract` takes `expand=False` only: `expand=True`, which returns a frame with a column per group, is refused and names `expand=False`.
- Splitting by a separator is not supported yet (komira-ai/komira#2375): `.str.split()` raises an error saying the plan has no node for it, and SQL `split_part` is refused because the engine cannot index a list. `probe_split_expand.py` beside this page tries `.str.split(" ", expand=True)` and must fail with the line in `probe_split_expand.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- `.str.partition()` and `.str.rsplit()` are refused the same way, and `substr(full_name, 1, strpos(full_name, ' ') - 1)` is refused because `substr` takes only an integer literal as its length.
- SQL `string_split(full_name, ' ')` works and returns one list per row, but a list cannot be indexed into columns.

## Related

- [How do I extract part of a string with a regex?](../40-extract-part-string-regex/page.md) (rank 40, works)
- [How do I concatenate string columns?](../43-concatenate-string-columns/page.md) (rank 43, partial)
- [How do I lowercase, trim and replace text in a column?](../42-lowercase-trim-replace-text-column/page.md) (rank 42, works)
- How do I flatten nested JSON into columns? (rank 45, gap; no page yet)
