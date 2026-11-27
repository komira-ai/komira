from pathlib import Path

import komira

Path("sales.csv").write_text(
    "day_no,sales\n"
    "1,10\n"
    "2,20\n"
    "3,60\n"
    "4,40\n"
    "5,50\n"
)

# SQL: average over the row and the two before it, in day order.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    avg = s.sql(
        "SELECT day_no, sales,"
        " avg(sales) OVER (ORDER BY day_no ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS avg3"
        " FROM sales ORDER BY day_no"
    )
    print(avg.to_arrow().to_pylist())

# pandas-shaped: sort the frame, then rolling(3).mean() of a column.
df = komira.read_csv("sales.csv").sort_values("day_no")
full = df.assign(avg3=df["sales"].rolling(3).mean())
print(full.materialize().to_arrow().column("avg3").to_pylist())

# min_periods=1 averages the first rows over the rows there are, as the SQL does.
early = df.assign(avg3=df["sales"].rolling(3, min_periods=1).mean())
print(early.materialize().to_arrow().to_pylist())
