# How do I standardize inconsistent category spellings?

Trim and lower-case the column in SQL, then map the remaining misspellings with a lookup table joined in or a `CASE`; the pandas-shaped frame can trim (with a regex) and lower-case.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("sales.csv").write_text(
    "id,category,amount\n"
    "1,Books,10\n"
    "2,  books,20\n"
    "3,BOOKS ,5\n"
    "4,Toys,7\n"
    "5,toys,8\n"
    "6,Tys,3\n"
    "7,Games,4\n"
    "8,games,6\n"
)
# A table of known misspellings and what each should become.
Path("fixes.csv").write_text("raw,clean\ntys,toys\n")

# SQL: trim and lower-case, then map the known misspellings through a lookup table.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.register_csv("fixes", "fixes.csv")
    print(
        s.sql(
            "SELECT coalesce(f.clean, c.category) AS category, sum(c.amount) AS total"
            " FROM (SELECT lower(trim(category)) AS category, amount FROM sales) c"
            " LEFT JOIN fixes f ON c.category = f.raw"
            " GROUP BY 1 ORDER BY 1"
        )
        .to_arrow()
        .to_pylist()
    )

    # For a few fixes, a CASE does it without a table.
    print(
        s.sql(
            "SELECT category, count(*) AS rows FROM ("
            " SELECT CASE WHEN lower(trim(category)) = 'tys' THEN 'toys'"
            "  ELSE lower(trim(category)) END AS category FROM sales)"
            " GROUP BY category ORDER BY category"
        )
        .to_arrow()
        .to_pylist()
    )

# pandas-shaped: a regex strips the whitespace, .str.lower() fixes the case.
df = komira.read_csv("sales.csv")
df["category"] = df["category"].str.replace(r"^\s+|\s+$", "", regex=True).str.lower()
totals = df.groupby("category", as_index=False)["amount"].sum().sort_values("category")
print(totals.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'category': 'books', 'total': Decimal('35')}, {'category': 'games', 'total': Decimal('10')}, {'category': 'toys', 'total': Decimal('18')}]
[{'category': 'books', 'rows': 3}, {'category': 'games', 'rows': 2}, {'category': 'toys', 'rows': 3}]
[{'category': 'books', 'amount': 35}, {'category': 'games', 'amount': 10}, {'category': 'toys', 'amount': 15}, {'category': 'tys', 'amount': 3}]
```

## Notes

- `trim()` removes spaces and `lower()` fixes case, so `Books`, `  books` and `BOOKS ` become `books` and group together.
- A lookup table (`fixes.csv`, joined with `LEFT JOIN` and `coalesce`) turns known misspellings into the right value and leaves every other value as cleaned; a `CASE` does the same for a few fixes.
- On the pandas-shaped frame `.str.strip()` is not supported yet (the engine trims spaces only, and pandas trims all whitespace), so the example strips with `.str.replace(r"^\s+|\s+$", "", regex=True)` and then `.str.lower()` (komira-ai/komira#2371). That frame has no `Series.map` (komira-ai/komira#2370). After the clean-up, `df["category"].replace("tys", "toys")` maps a known misspelling by exact match ([rank 55](../55-replace-values-with-null/page.md)); the example leaves it out, so `tys` stays a separate group in its output.
- The polars-shaped frame has `str.to_lowercase()` but no `strip_chars()` or `replace()` yet (komira-ai/komira#2371), so the example does not use it.

## Related

- [How do I lowercase, trim and replace text in a column?](../42-lowercase-trim-replace-text-column/page.md) (rank 42, partial)
- How do I add a column with if/else (case when) logic? (rank 30, works; no page yet)
- [How do I find (not drop) duplicate rows?](../57-find-duplicate-rows/page.md) (rank 57, works)
- [How do I replace specific values such as 'N/A' with null?](../55-replace-values-with-null/page.md) (rank 55, partial)
