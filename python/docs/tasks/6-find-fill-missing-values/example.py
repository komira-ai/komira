from pathlib import Path

import komira
import komira.pl as kpl

# A small CSV file: an empty field reads as NULL.
Path("readings.csv").write_text(
    "id,city,score,qty\n"
    "1,Oslo,12.5,3\n"
    "2,,8.0,\n"
    "3,Lima,,\n"
    "4,Rome,,\n"
)

# SQL: IS NULL finds the rows, count(*) less count(column) counts the missing
# values of each column, and COALESCE puts a value where one is missing.
with komira.Session() as s:
    s.register_csv("readings", "readings.csv")
    no_score = s.sql("SELECT id FROM readings WHERE score IS NULL ORDER BY id")
    print(no_score.to_arrow().to_pylist())
    counts = s.sql(
        "SELECT count(*) - count(city) AS city_missing,"
        " count(*) - count(score) AS score_missing,"
        " count(*) - count(qty) AS qty_missing FROM readings"
    )
    print(counts.to_arrow().to_pylist())
    filled = s.sql(
        "SELECT id, COALESCE(city, 'unknown') AS city,"
        " COALESCE(score, 0) AS score, COALESCE(qty, 0) AS qty"
        " FROM readings ORDER BY id"
    )
    print(filled.to_arrow().to_pylist())

# pandas-shaped: fillna takes a dict of a value per column, or one value for
# every column of the frame.
df = komira.read_csv("readings.csv")
by_column = df.fillna({"city": "unknown", "score": 0.0, "qty": 0})
print(by_column.sort_values("id").materialize().to_arrow().to_pylist())
numbers = df[["id", "score", "qty"]].fillna(0)
print(numbers.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: is_null().sum() counts the nulls of a column, is_null()
# filters on them, and fill_null fills them.
lf = kpl.scan_csv("readings.csv")
nulls = lf.select(
    kpl.col("city").is_null().sum(),
    kpl.col("score").is_null().sum(),
    kpl.col("qty").is_null().sum(),
)
print(nulls.collect().to_arrow().to_pylist())
missing = lf.filter(kpl.col("score").is_null()).select("id").sort("id")
print(missing.collect().to_arrow().to_pylist())
fill = [
    kpl.col("city").fill_null("unknown"),
    kpl.col("score").fill_null(0.0),
    kpl.col("qty").fill_null(0),
]
print(lf.with_columns(*fill).sort("id").collect().to_arrow().to_pylist())
