# How do I convert a Unix timestamp to a datetime and back?

In SQL, `make_timestamp(unix_s * 1000000)` (or `make_timestamp_ms(unix_ms)`) makes a TIMESTAMP, and `date_diff('second', origin, ts)` against a column holding `make_timestamp(0)` gives the Unix timestamp back.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# Unix timestamps in seconds and in milliseconds.
Path("events.csv").write_text(
    "unix_s,unix_ms\n"
    "1788220800,1788220800123\n"
    "1788224461,1788224461500\n"
    "1788438896,1788438896007\n"
)

with komira.Session() as s:
    s.register_csv("events", "events.csv")

    # Seconds to TIMESTAMP: make_timestamp counts microseconds since the Unix epoch.
    seconds = s.sql(
        "SELECT unix_s, make_timestamp(unix_s * 1000000) AS ts FROM events ORDER BY unix_s"
    )
    for row in seconds.to_arrow().to_pylist():
        print(row["unix_s"], row["ts"])

    # Milliseconds to TIMESTAMP: make_timestamp_ms counts milliseconds.
    millis = s.sql(
        "SELECT unix_ms, make_timestamp_ms(unix_ms) AS ts FROM events ORDER BY unix_ms"
    )
    for row in millis.to_arrow().to_pylist():
        print(row["unix_ms"], row["ts"])

    # Back: the units between the Unix epoch, make_timestamp(0) kept in a
    # column, and the timestamp. date_diff takes columns, not the call itself.
    back = s.sql(
        "SELECT unix_s, date_diff('second', origin, ts) AS back_s,"
        " unix_ms, date_diff('millisecond', origin, ts_ms) AS back_ms"
        " FROM (SELECT unix_s, unix_ms, make_timestamp(0) AS origin,"
        " make_timestamp(unix_s * 1000000) AS ts,"
        " make_timestamp_ms(unix_ms) AS ts_ms FROM events) AS e"
        " ORDER BY unix_s"
    )
    for row in back.to_arrow().to_pylist():
        print(row)
```

Output:

<!-- include expected_output.txt -->
```text
1788220800 2026-09-01 00:00:00
1788224461 2026-09-01 01:01:01
1788438896 2026-09-03 12:34:56
1788220800123 2026-09-01 00:00:00.123000
1788224461500 2026-09-01 01:01:01.500000
1788438896007 2026-09-03 12:34:56.007000
{'unix_s': 1788220800, 'back_s': 1788220800, 'unix_ms': 1788220800123, 'back_ms': 1788220800123}
{'unix_s': 1788224461, 'back_s': 1788224461, 'unix_ms': 1788224461500, 'back_ms': 1788224461500}
{'unix_s': 1788438896, 'back_s': 1788438896, 'unix_ms': 1788438896007, 'back_ms': 1788438896007}
```

## Notes

- `make_timestamp(n)` reads `n` as microseconds since the Unix epoch and `make_timestamp_ms(n)` reads milliseconds; both answer a TIMESTAMP, which Python receives as a `datetime.datetime`. The argument must be an integer: a DOUBLE is refused by name, so cast it to BIGINT first.
- A multiplication that does not fit in 64 bits raises an overflow error; it does not wrap.
- `date_diff(unit, a, b)` takes two TIMESTAMP columns (or literals), so the Unix epoch has to sit in a column: `make_timestamp(0)` is named in a subquery and read from the outer query. A call written directly as the argument is refused.
- `epoch(ts)`, `epoch_ms(ts)`, `to_timestamp(n)`, `date_part('epoch', ts)` and `CAST(ts AS BIGINT)` are not served yet, and neither is `komira.to_datetime(s, unit="s")` on the pandas-shaped frame: komira-ai/komira#2344.
- `probe_to_datetime.py` beside this page tries `komira.to_datetime` and must fail with the line in `probe_to_datetime.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.

## Related

- How do I filter rows by a date range? (rank 83, works)
- How do I split events into sessions by time gap? (rank 84, works)
- How do I group by month or week? (rank 80, works; no page yet)
- How do I fill gaps in a time series so every date is present? (rank 81, gap; no page yet)
