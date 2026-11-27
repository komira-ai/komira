from pathlib import Path

import komira

# Sales per store and day, not in order.
Path("sales.csv").write_text(
    "store,day,amount\n"
    "north,2,30\n"
    "south,1,5\n"
    "north,1,10\n"
    "south,2,15\n"
    "north,3,20\n"
)

# SQL: a window function, one running total per store.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    sql = (
        "SELECT store, day, amount,"
        " SUM(amount) OVER (PARTITION BY store ORDER BY day"
        " ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running"
        " FROM sales ORDER BY store, day"
    )
    for row in s.sql(sql).to_arrow().to_pylist():
        print(row)

# pandas-shaped: sort, then cumsum within each group.
df = komira.read_csv("sales.csv").sort_values(["store", "day"])
df["running"] = df.groupby("store")["amount"].cumsum()
print(df.materialize().to_arrow().to_pylist())
