from pathlib import Path

import komira

Path("sales.csv").write_text(
    "order_id,amount,year,month\n"
    "1,120,2027,1\n"
    "2,40,2027,2\n"
    "3,75,2028,1\n"
    "4,200,2027,1\n"
)

with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    # PARTITION_BY writes one directory per (year, month) pair, with one file in each.
    written = s.sql(
        "COPY (SELECT order_id, amount, year, month FROM sales ORDER BY order_id)"
        " TO 'sales_by_month' (FORMAT parquet, PARTITION_BY (year, month))"
    ).to_arrow()
    print("rows written:", written.column(0).to_pylist()[0])

    # The files, named relative to the directory.
    tree = Path("sales_by_month")
    for name in sorted(p.relative_to(tree).as_posix() for p in tree.rglob("*.parquet")):
        print(name)

    # Read the tree back: the year and month directories become columns again.
    s.register_parquet("back", "sales_by_month/**/*.parquet")
    print(s.sql("SELECT order_id, amount, year, month FROM back ORDER BY order_id").to_arrow().to_pylist())

    # A WHERE on a partition column reads only the matching directory.
    print(s.sql("SELECT order_id FROM back WHERE year = 2027 AND month = 1 ORDER BY order_id").to_arrow().to_pylist())
