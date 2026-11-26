from pathlib import Path

import komira

Path("days.csv").write_text(
    "id,d\n"
    "1,2026-10-01\n"
    "2,2026-10-03\n"
    "3,2026-11-15\n"
    "4,2026-12-25\n"
)

# SQL: year(), month() and isodow() (Monday is 1 ... Sunday is 7) read a date.
with komira.Session() as s:
    s.register_csv("days", "days.csv")
    parts = s.sql(
        "SELECT d, year(d) AS yr, month(d) AS mon, isodow(d) AS dow"
        " FROM days ORDER BY d"
    )
    print(parts.to_arrow().to_pylist())

# pandas-shaped: the .dt accessor of a date column. Monday is 0, as in pandas.
df = komira.read_csv("days.csv")
parts = df.assign(
    year=df["d"].dt.year,
    month=df["d"].dt.month,
    weekday=df["d"].dt.weekday,
)[["d", "year", "month", "weekday"]]
print(parts.sort_values("d").materialize().to_arrow().to_pylist())

# The parts are ordinary columns: here, the rows that fall on a weekend.
weekend = df[df["d"].dt.weekday >= 5][["id"]]
print(weekend.sort_values("id").materialize().to_arrow().to_pylist())
