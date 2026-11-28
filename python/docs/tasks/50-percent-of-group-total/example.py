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

# SQL: a window SUM gives each row its group total; a second SELECT divides.
# round(x, 1) keeps one decimal.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    shares = s.sql(
        "SELECT region, rep, amount, round(amount * 100.0 / total, 1) AS pct"
        " FROM (SELECT region, rep, amount,"
        " SUM(amount) OVER (PARTITION BY region) AS total FROM sales)"
        " ORDER BY region, rep"
    )
    print(shares.to_arrow().to_pylist())

# pandas-shaped: divide by the group's transform('sum'), then round to one decimal.
df = komira.read_csv("sales.csv")
df["pct"] = (df["amount"] / df.groupby("region")["amount"].transform("sum") * 100).round(1)
for row in df.sort_values("rep").materialize().to_arrow().to_pylist():
    print(row["rep"], row["pct"])
