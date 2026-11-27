from pathlib import Path

import komira
from komira import pl

Path("readings.csv").write_text(
    "sensor,count,level\n"
    "a,12,12.5\n"
    "b,oops,n/a\n"
    "c,7,7\n"
    "d,,\n"
    "e,3,3.25\n"
)

# polars-shaped: cast with strict=False makes a value that is not a number null.
numbers = (
    pl.scan_csv("readings.csv")
    .with_columns(
        pl.col("count").cast("int64", strict=False),
        pl.col("level").cast("float64", strict=False),
    )
    .sort("sensor")
    .collect()
)
print(numbers.to_arrow().to_pylist())

# The converted column is a number, so it aggregates: nulls are skipped.
totals = (
    pl.scan_csv("readings.csv")
    .select(
        pl.col("count").cast("int64", strict=False).sum().alias("count_sum"),
        pl.col("level").cast("float64", strict=False).mean().alias("level_mean"),
    )
    .collect()
)
row = totals.to_arrow().to_pylist()[0]
print(row["count_sum"], f"{row['level_mean']:.2f}")

# pandas-shaped: astype converts a clean column, but a value that is not a
# number fails the query instead of becoming null.
df = komira.read_csv("readings.csv")
try:
    df.assign(count=df["count"].astype("int64")).materialize()
except komira.KomiraError:
    print("astype failed")

# SQL: TRY_CAST makes a value that is not a number NULL; CAST fails the query.
# Text reads as DuckDB reads it: '2.5' is 3 as a BIGINT, and '1e3' is a number.
Path("raw.csv").write_text("sensor,reading\na,12\nb,oops\nc,2.5\nd,\ne,1e3\n")
with komira.Session() as s:
    s.register_csv("raw", "raw.csv")
    rows = s.sql(
        "SELECT sensor, TRY_CAST(reading AS BIGINT) AS n, TRY_CAST(reading AS DOUBLE) AS x"
        " FROM raw ORDER BY sensor"
    )
    print(rows.to_arrow().to_pylist())
    try:
        s.sql("SELECT CAST(reading AS BIGINT) AS n FROM raw").to_arrow()
    except komira.KomiraError:
        print("CAST failed")
