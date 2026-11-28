# How do I parse strings into dates?

`CAST(text AS DATE)`, `TRY_CAST(text AS DATE)` and `strptime(text, '<format>')` parse text in SQL, and `astype("date32")` parses a string column of a frame; a few `strptime` directives are still refused.

<!-- include example.py -->
```python
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira

# ISO text ("2026-09-15") is read as a date by the CSV reader itself.
Path("orders.csv").write_text(
    "id,shipped\n"
    "1,2026-09-15\n"
    "2,2026-10-01\n"
    "3,2026-12-31\n"
)
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    result = s.sql(
        "SELECT id, shipped, month(shipped) AS month,"
        " date_diff('day', DATE '2026-09-01', shipped) AS days"
        " FROM orders WHERE shipped >= DATE '2026-10-01' ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())

# Any other format: strptime(text, format) parses the text in SQL. The format
# is a constant string of % directives and the result is a timestamp.
Path("us_orders.csv").write_text(
    "id,shipped\n"
    "1,09/15/2026\n"
    "2,10/20/2026\n"
    "3,12/31/2026\n"
)
with komira.Session() as s:
    s.register_csv("us_orders", "us_orders.csv")
    result = s.sql(
        "SELECT id, strptime(shipped, '%m/%d/%Y') AS shipped"
        " FROM us_orders ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())

# ISO text held as a string column: CAST gives a date, TRY_CAST gives NULL for
# text that is not a date (a column that mixes dates with "unknown" is text).
Path("text_dates.csv").write_text(
    "id,shipped\n"
    "1,2026-09-15\n"
    "2,unknown\n"
    "3,2026-12-31\n"
)
with komira.Session() as s:
    s.register_csv("text_dates", "text_dates.csv")
    result = s.sql(
        "SELECT id, TRY_CAST(shipped AS DATE) AS shipped"
        " FROM text_dates ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())
    s.register_csv("text_ok", "orders.csv", all_varchar=True)
    result = s.sql(
        "SELECT id, CAST(shipped AS DATE) AS shipped FROM text_ok ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())

# pandas-shaped: astype("date32") on a string column parses it like CAST.
pq.write_table(
    pa.table({"id": [1, 2], "shipped": ["2026-09-15", "2026-10-01"]}),
    "strings.parquet",
)
df = komira.read_parquet("strings.parquet")
typed = df.astype({"shipped": "date32"}).sort_values("id").materialize().to_arrow()
print(typed.schema.field("shipped").type)
print(typed.to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
date32[day]
[{'id': 2, 'shipped': datetime.date(2026, 10, 1), 'month': 10, 'days': 30}, {'id': 3, 'shipped': datetime.date(2026, 12, 31), 'month': 12, 'days': 121}]
timestamp[us]
[{'id': 1, 'shipped': datetime.datetime(2026, 9, 15, 0, 0)}, {'id': 2, 'shipped': datetime.datetime(2026, 10, 20, 0, 0)}, {'id': 3, 'shipped': datetime.datetime(2026, 12, 31, 0, 0)}]
date32[day]
[{'id': 1, 'shipped': datetime.date(2026, 9, 15)}, {'id': 2, 'shipped': None}, {'id': 3, 'shipped': datetime.date(2026, 12, 31)}]
date32[day]
[{'id': 1, 'shipped': datetime.date(2026, 9, 15)}, {'id': 2, 'shipped': datetime.date(2026, 10, 1)}, {'id': 3, 'shipped': datetime.date(2026, 12, 31)}]
date32[day]
[{'id': 1, 'shipped': datetime.date(2026, 9, 15)}, {'id': 2, 'shipped': datetime.date(2026, 10, 1)}]
```

## Notes

- `register_csv` types a column of `YYYY-MM-DD` values as a date (`date32`), so `year`, `month`, `date_diff` and comparisons with `DATE '...'` work on it with no parsing step. A column that mixes dates with other text, or is read with `all_varchar=True`, stays a string column and is parsed with the forms below.
- `CAST(<text> AS DATE)` and `CAST(<text> AS TIMESTAMP)` accept what DuckDB accepts: optional leading and trailing whitespace; `YYYY-MM-DD` with `-`, `/`, `\` or a space as the separator (the same one twice); a month and day of one or two digits; an optional ` (BC)`; and text after the day that is not a digit is ignored (`2026-09-15 10:11` is `2026-09-15`). Text that does not parse, and a day that does not exist (`2026-02-30`), fail the query under `CAST` and give NULL under `TRY_CAST`. A NULL input gives NULL. See <https://duckdb.org/docs/stable/sql/expressions/cast.html>.
- `strptime(text, format)` and `try_strptime(text, format)` return a `TIMESTAMP` (microseconds), as DuckDB does; `try_strptime` gives NULL for text that does not match. The format must be a constant string. Supported directives: `%Y %y %-y %m %-m %d %-d %b %h %B %a %A %H %-H %I %-I %p %M %-M %S %-S %f %g %j %-j %c %x %X %T %%`. Refused by name: `%z` and `%Z` (DuckDB returns a `TIMESTAMP WITH TIME ZONE`), `%n` (a `TIMESTAMP_NS`), the week-based `%G %V %u %U %W %w`, and a list of formats. See <https://duckdb.org/docs/stable/sql/functions/dateformat.html> and <https://duckdb.org/docs/stable/sql/functions/timestamp.html>.
- In the pandas-shaped frame, `Series.astype("date32")` and `DataFrame.astype({"col": "date32"})` on a string column parse the text as `CAST(... AS DATE)` does, and a value that does not parse fails the query. `astype` to a timestamp dtype from text is still refused.
- `komira.to_datetime()` is refused and points at `astype`; the polars-shaped `cast` of text to a date is not changed by this.
- Still refused, so the status is partial (komira-ai/komira#2366): the directives and the list of formats named above, a format that is not a constant, and `astype` of text to a timestamp dtype.

## Related

- [How do I change a column's data type?](../12-change-column-data-type/page.md) (rank 12, works)
- [How do I extract year, month and weekday from a date column?](../39-extract-year-month-weekday-date-column/page.md) (rank 39, partial)
- How do I add days to a date or take the difference between dates? (rank 79, partial; no page yet)
- How do I filter rows by a date range? (rank 83, works; no page yet)
