# How do I find and fill missing values?

Find them with `IS NULL` and `count(*) - count(column)` in SQL, `isna()` and `notna()` on the pandas-shaped frame, or `col(...).is_null()` on the polars-shaped frame, and fill them with `COALESCE`, `fillna` or `fill_null`.

<!-- include example.py -->
```python
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

# pandas-shaped: isna() marks each missing value, so isna().sum() counts them
# per column; a column's isna() filters on them and notna() makes a column.
df = komira.read_csv("readings.csv")
print(df.isna().sum().materialize().to_arrow().to_pylist())
no_score = df[df["score"].isna()][["id"]]
print(no_score.sort_values("id").materialize().to_arrow().to_pylist())
marked = df.assign(has_score=df["score"].notna())[["id", "has_score"]]
print(marked.sort_values("id").materialize().to_arrow().to_pylist())

# fillna takes a dict of a value per column, or one value for every column of
# the frame.
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
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 3}, {'id': 4}]
[{'city_missing': 1, 'score_missing': 2, 'qty_missing': 3}]
[{'id': 1, 'city': 'Oslo', 'score': 12.5, 'qty': 3}, {'id': 2, 'city': 'unknown', 'score': 8.0, 'qty': 0}, {'id': 3, 'city': 'Lima', 'score': 0.0, 'qty': 0}, {'id': 4, 'city': 'Rome', 'score': 0.0, 'qty': 0}]
[{'id': 0, 'city': 1, 'score': 2, 'qty': 3}]
[{'id': 3}, {'id': 4}]
[{'id': 1, 'has_score': True}, {'id': 2, 'has_score': True}, {'id': 3, 'has_score': False}, {'id': 4, 'has_score': False}]
[{'id': 1, 'city': 'Oslo', 'score': 12.5, 'qty': 3}, {'id': 2, 'city': 'unknown', 'score': 8.0, 'qty': 0}, {'id': 3, 'city': 'Lima', 'score': 0.0, 'qty': 0}, {'id': 4, 'city': 'Rome', 'score': 0.0, 'qty': 0}]
[{'id': 1, 'score': 12.5, 'qty': 3}, {'id': 2, 'score': 8.0, 'qty': 0}, {'id': 3, 'score': 0.0, 'qty': 0}, {'id': 4, 'score': 0.0, 'qty': 0}]
[{'city': 1, 'score': 2, 'qty': 3}]
[{'id': 3}, {'id': 4}]
[{'id': 1, 'city': 'Oslo', 'score': 12.5, 'qty': 3}, {'id': 2, 'city': 'unknown', 'score': 8.0, 'qty': 0}, {'id': 3, 'city': 'Lima', 'score': 0.0, 'qty': 0}, {'id': 4, 'city': 'Rome', 'score': 0.0, 'qty': 0}]
```

## Notes

- A missing value is NULL, and an empty CSV field reads as NULL. `count(*)` counts the rows and `count(column)` the values that are not NULL, so their difference is the number of missing values.
- On the pandas-shaped frame, `df.isna()` is a frame of booleans with the same column names, so `df.isna().sum()` gives one row with the count of missing values of each column; `df.notna()` is its negation. On a column, `df["score"].isna()` and `notna()` are boolean Series, never NULL, used as a filter or assigned as a column. `isnull` and `notnull` are the same methods.
- On the pandas-shaped frame a NaN in a float column is missing as NULL is, for `isna`, `notna`, `dropna` and `fillna` alike; on the polars-shaped frame `is_null()` finds NULL only.
- `fillna` on the pandas-shaped frame fills with a value of the column's own type: an int for an integer column, an int or a float for a float column, a str for a text column. A column keeps its type, so `df.fillna(0)` on a frame with a text column is refused: pass a dict of values by column, or select the number columns first, as above. A NaN in a float column is filled too.
- `fillna` refuses `method=`, `limit=`, `axis=1` and `inplace=True`, and a Series or frame as the value: a frame has no row order or index to fill by. `ffill()`, `bfill()` and `interpolate()` are not supported yet.
- `fill_null` on the polars-shaped frame takes a value: `strategy=` and `limit=` raise `UnsupportedOperation`, "fill_null: strategy= and limit= fill from neighbouring rows, which a plan does not order; fill with a value: fill_null(value)". A NaN is not null there.
- In SQL, an integer literal beside a float column in `COALESCE` is read as a float, so `COALESCE(score, 0)` is a float column.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`.

## Related

- [How do I drop rows with missing values?](../7-drop-rows-missing-values/page.md) (rank 7, works)
- How do I replace specific values such as 'N/A' with null? (rank 55, works; no page yet)
- [How do I change a column's data type?](../12-change-column-data-type/page.md) (rank 12, works)
- How do I validate data: nulls, uniqueness, ranges? (rank 59, works; no page yet)
