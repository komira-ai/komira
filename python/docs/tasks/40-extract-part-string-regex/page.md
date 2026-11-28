# How do I extract part of a string with a regex?

Call `regexp_extract(text, pattern, group)` in SQL, or `Series.str.extract(pattern, expand=False)` on a pandas-shaped frame, with the part you want inside one pair of parentheses.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("contacts.csv").write_text(
    "id,contact\n"
    "1,ana@shop.example\n"
    "2,bo@mail.example\n"
    "3,no email\n"
    "4,cy@shop.example\n"
)

# SQL: regexp_extract(text, pattern, group) returns the text of one capture group.
with komira.Session() as s:
    s.register_csv("contacts", "contacts.csv")
    domains = s.sql(
        "SELECT id, regexp_extract(contact, '@([a-z.]+)', 1) AS domain"
        " FROM contacts ORDER BY id"
    )
    print(domains.to_arrow().to_pylist())

# pandas-shaped: Series.str.extract with one capture group and expand=False.
df = komira.read_csv("contacts.csv")
df = df.assign(domain=df["contact"].str.extract(r"@([a-z.]+)", expand=False))
print(df.sort_values("id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'domain': 'shop.example'}, {'id': 2, 'domain': 'mail.example'}, {'id': 3, 'domain': ''}, {'id': 4, 'domain': 'shop.example'}]
[{'id': 1, 'contact': 'ana@shop.example', 'domain': 'shop.example'}, {'id': 2, 'contact': 'bo@mail.example', 'domain': 'mail.example'}, {'id': 3, 'contact': 'no email', 'domain': ''}, {'id': 4, 'contact': 'cy@shop.example', 'domain': 'shop.example'}]
```

## Notes

- A string the pattern does not match gives an empty string `''`, as in DuckDB, where pandas gives `NaN`. Row 3 shows it.
- In SQL, `group` is an integer literal: 1 is the first pair of parentheses and 0 (or leaving it out) is the whole match. The pattern is a string literal too.
- `str.extract` takes a pattern with exactly one capture group and `expand=False`. A pattern with several groups, or `expand=True`, is refused by name: extract each group in its own call. Python `re` flags are refused; in SQL pass DuckDB's option letters as a fourth argument, for example `'i'` to ignore case.
- To keep only the rows that match, filter with `regexp_matches(contact, '@')` in SQL or `str.contains` on the frame.

## Related

- [How do I filter rows where a text column contains a substring?](../41-filter-rows-text-column-contains-substring/page.md) (rank 41, works)
- [How do I lowercase, trim and replace text in a column?](../42-lowercase-trim-replace-text-column/page.md) (rank 42, works)
- [How do I split a string column into several columns?](../44-split-string-column-columns/page.md) (rank 44, partial)
