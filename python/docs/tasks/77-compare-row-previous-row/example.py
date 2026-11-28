from pathlib import Path

import komira
import komira.pl as kpl

# Daily sales, one row per step t.
Path("sales.csv").write_text("t,sales\n1,10\n2,13\n3,13\n4,9\n")

# SQL: lag looks at the previous row in the window's order, lead at the next
# one; both read NULL where there is no such row. The change from the
# previous row is the value minus its lag, taken in an outer query.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    for row in s.sql(
        "SELECT t, sales, prev, nxt, sales - prev AS change FROM ("
        "  SELECT t, sales,"
        "  lag(sales) OVER (ORDER BY t) AS prev,"
        "  lead(sales) OVER (ORDER BY t) AS nxt"
        "  FROM sales"
        ") ORDER BY t"
    ).to_arrow().to_pylist():
        print(row)

# pandas-shaped: sort the frame, then shift, diff and pct_change of a column.
# shift(-1) looks one row ahead; diff and pct_change answer floats, as pandas.
df = komira.read_csv("sales.csv").sort_values("t")
changes = df.assign(
    prev=df["sales"].shift(1),
    nxt=df["sales"].shift(-1),
    change=df["sales"].diff(),
    pct=df["sales"].pct_change(),
)
for row in changes.materialize().to_arrow().to_pylist():
    row["pct"] = None if row["pct"] is None else round(row["pct"], 4)
    print(row)

# polars-shaped: shift and diff on a sorted frame; diff keeps the int type.
lf = kpl.scan_csv("sales.csv").sort("t").with_columns(
    kpl.col("sales").shift(1).alias("prev"),
    kpl.col("sales").diff().alias("change"),
)
for row in lf.collect().to_arrow().to_pylist():
    print(row)
