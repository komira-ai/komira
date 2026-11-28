from pathlib import Path

import komira

Path("sales.csv").write_text(
    "region,rep,amount\n"
    "east,Ana,120\n"
    "east,Bo,80\n"
    "west,Cy,50\n"
    "west,Di,150\n"
    "west,Ed,100\n"
    "north,Flo,200\n"
)

# SQL: SUM(amount) OVER (PARTITION BY region) is each row's group total, and
# the division reads it in the same SELECT. Scaling by 1000, rounding and
# dividing by 10 keeps one decimal.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    shares = s.sql(
        "SELECT region, rep, amount,"
        " round(amount * 1000.0 / SUM(amount) OVER (PARTITION BY region)) / 10 AS pct"
        " FROM sales ORDER BY region, rep"
    )
    print(shares.to_arrow().to_pylist())
    # SELECT * beside a window: the table's columns, then the window's.
    totals = s.sql(
        "SELECT *, SUM(amount) OVER (PARTITION BY region) AS total"
        " FROM sales ORDER BY rep"
    )
    print(totals.to_arrow().to_pylist())

# pandas-shaped: divide by the group's transform('sum'), round when printing.
df = komira.read_csv("sales.csv")
df["pct"] = df["amount"] / df.groupby("region")["amount"].transform("sum") * 100
for row in df.sort_values("rep").materialize().to_arrow().to_pylist():
    print(row["rep"], f"{row['pct']:.1f}")
