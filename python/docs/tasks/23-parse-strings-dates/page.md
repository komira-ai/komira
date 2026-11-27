# How do I parse strings into dates?

komira reads ISO text (`2026-09-15`) as a date when it reads the file; for any other format, parse the text with pyarrow first and give komira the dates.

<!-- include example.py -->
```python
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
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

# Any other format: parse the text with pyarrow, then give komira the dates.
text = pa.table({"id": [1, 2, 3], "shipped": ["09/15/2026", "10/20/2026", "12/31/2026"]})
parsed = pc.strptime(text["shipped"], format="%m/%d/%Y", unit="s").cast(pa.date32())
pq.write_table(text.set_column(1, "shipped", parsed), "us_orders.parquet")
with komira.Session() as s:
    s.register_parquet("us_orders", "us_orders.parquet")
    result = s.sql(
        "SELECT id, shipped, year(shipped) AS year FROM us_orders"
        " WHERE shipped < DATE '2026-12-01' ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
date32[day]
[{'id': 2, 'shipped': datetime.date(2026, 10, 1), 'month': 10, 'days': 30}, {'id': 3, 'shipped': datetime.date(2026, 12, 31), 'month': 12, 'days': 121}]
date32[day]
[{'id': 1, 'shipped': datetime.date(2026, 9, 15), 'year': 2026}, {'id': 2, 'shipped': datetime.date(2026, 10, 20), 'year': 2026}]
```

## Notes

- `register_csv` types a column of `YYYY-MM-DD` values as a date (`date32`), so `year`, `month`, `date_diff` and comparisons with `DATE '...'` work on it with no parsing step.
- komira's SQL cannot parse text itself yet: `CAST(<text> AS DATE)` and `CAST(<text> AS TIMESTAMP)` are refused by name, and so is `strptime` (komira-ai/komira#2366). `probe_cast_date.py` and `probe_strptime.py` beside this page try both and must fail with the lines of their `.error.txt` files. The day one runs, this page's check goes red, and the page and the catalogue status change with it.
- The program parses with `pyarrow.compute.strptime` (a format of `%` directives, as in Python), casts the result to a date, and writes Parquet for komira to read. A value that does not match the format raises in pyarrow, so a bad row is found before komira sees it.
- The pandas-shaped frame's `komira.to_datetime(s, unit=...)` takes integer Unix counts only; text, and its `format=` argument, are refused by name, and `astype` does not parse text into dates today.

## Related

- [How do I change a column's data type?](../12-change-column-data-type/page.md) (rank 12, works)
- [How do I extract year, month and weekday from a date column?](../39-extract-year-month-weekday-date-column/page.md) (rank 39, partial)
- How do I add days to a date or take the difference between dates? (rank 79, partial; no page yet)
- How do I filter rows by a date range? (rank 83, works; no page yet)
