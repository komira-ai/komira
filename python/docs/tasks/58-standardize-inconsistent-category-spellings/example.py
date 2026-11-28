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

# pandas-shaped: .str.strip() removes the whitespace, .str.lower() fixes the case.
df = komira.read_csv("sales.csv")
df["category"] = df["category"].str.strip().str.lower()
totals = df.groupby("category", as_index=False)["amount"].sum().sort_values("category")
print(totals.materialize().to_arrow().to_pylist())
