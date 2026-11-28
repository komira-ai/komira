from pathlib import Path

import komira
import komira.pl as kpl

Path("sales.csv").write_text(
    "sold_on,amount\n"
    "2026-10-01,10.5\n"
    "2026-10-01,4.5\n"
    "2026-10-02,20.0\n"
    "2026-10-05,7.5\n"
    "2026-10-07,8.5\n"
    "2026-10-31,4.0\n"
    "2026-11-02,6.5\n"
    "2026-11-03,9.5\n"
)

# SQL: date_trunc cuts each date down to the start of its day, week (Monday) or month,
# and ORDER BY sorts the buckets by date.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    for unit in ("day", "week", "month"):
        rows = s.sql(
            "SELECT bucket, sum(amount) AS total, count(*) AS n FROM ("
            f"SELECT date_trunc('{unit}', sold_on) AS bucket, amount FROM sales"
            ") AS b GROUP BY bucket ORDER BY bucket"
        )
        print(unit, rows.to_arrow().to_pylist())

# pandas-shaped: resample by the date column. pandas labels a day by itself, a
# week ("W") by the Sunday that ends it, and a month by its first day ("MS") or
# its last ("ME"). The buckets come in no order, so they are sorted in Python.
df = komira.read_csv("sales.csv")
for rule in ("D", "W", "MS", "ME"):
    totals = df.resample(rule, on="sold_on")["amount"].sum()
    print(rule, sorted(totals.materialize().to_arrow().to_pylist(), key=lambda r: r["sold_on"]))

# polars-shaped: group_by_dynamic names each window by its start, as
# col("sold_on").dt.truncate(every) does (a week starts on Monday).
lf = kpl.scan_csv("sales.csv")
for every in ("1d", "1w", "1mo"):
    windows = lf.group_by_dynamic("sold_on", every=every).agg(
        kpl.col("amount").sum().alias("total"), kpl.len().alias("n")
    )
    print(every, sorted(windows.collect().to_arrow().to_pylist(), key=lambda r: r["sold_on"]))
