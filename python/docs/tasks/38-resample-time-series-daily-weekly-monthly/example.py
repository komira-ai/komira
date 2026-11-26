from pathlib import Path

import komira

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

# SQL: date_trunc cuts each date down to the start of its day, week (Monday) or month.
# komira cannot sort by a date column yet, so the few buckets are sorted in Python.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    for unit in ("day", "week", "month"):
        rows = s.sql(
            "SELECT bucket, sum(amount) AS total, count(*) AS n FROM ("
            f"SELECT date_trunc('{unit}', sold_on) AS bucket, amount FROM sales"
            ") AS b GROUP BY bucket"
        )
        print(unit, sorted(rows.to_arrow().to_pylist(), key=lambda r: r["bucket"]))

# pandas-shaped: group by the date for days (sort=False, as the date is no sort
# key yet), or by its year and month for months.
df = komira.read_csv("sales.csv")
daily = df.groupby("sold_on", sort=False).agg(total=("amount", "sum"))
print(sorted(daily.materialize().to_arrow().to_pylist(), key=lambda r: r["sold_on"]))

df = df.assign(year=df["sold_on"].dt.year, month=df["sold_on"].dt.month)
monthly = df.groupby(["year", "month"]).agg(total=("amount", "sum"), n=("amount", "size"))
print(monthly.materialize().to_arrow().to_pylist())
