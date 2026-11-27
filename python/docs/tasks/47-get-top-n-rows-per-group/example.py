from pathlib import Path

import komira

Path("sales.csv").write_text(
    "region,rep,amount\n"
    "east,Ana,120\n"
    "east,Bo,80\n"
    "east,Cy,200\n"
    "east,Di,150\n"
    "west,Ed,90\n"
    "west,Flo,60\n"
    "west,Gus,300\n"
    "north,Hal,50\n"
)

# SQL: number the rows in each group with ROW_NUMBER, then keep numbers up to 2.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    top2 = s.sql(
        "SELECT region, rep, amount FROM ("
        " SELECT region, rep, amount,"
        " ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS rn"
        " FROM sales) ranked"
        " WHERE rn <= 2 ORDER BY region, amount DESC"
    )
    print(top2.to_arrow().to_pylist())

# pandas-shaped: rank within each group, keep the rows ranked 2 or better.
df = komira.read_csv("sales.csv")
rank = df.groupby("region")["amount"].rank(method="min", ascending=False)
top2 = df[rank <= 2].sort_values(["region", "amount"], ascending=[True, False])
print(top2.materialize().to_arrow().to_pylist())
