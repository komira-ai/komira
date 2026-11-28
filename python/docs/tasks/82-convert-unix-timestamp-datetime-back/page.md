# How do I convert a Unix timestamp to a datetime and back?

In SQL, `make_timestamp(unix_s * 1000000)` or `epoch_ms(unix_ms)` makes a TIMESTAMP, and `epoch(ts)`, `epoch_ms(ts)` and `epoch_us(ts)` give the Unix timestamp back; on the pandas-shaped frame, `komira.to_datetime(s, unit="s")`. `to_timestamp(n)` is not served yet.

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

    # To TIMESTAMP: make_timestamp counts microseconds since the Unix epoch,
    # and epoch_ms of a BIGINT counts milliseconds.
    to_ts = s.sql(
        "SELECT unix_s, make_timestamp(unix_s * 1000000) AS ts,"
        " unix_ms, epoch_ms(unix_ms) AS ts_ms FROM events ORDER BY unix_s"
    )
    for row in to_ts.to_arrow().to_pylist():
        print(row["unix_s"], row["ts"], row["unix_ms"], row["ts_ms"])

    # Back: epoch(ts) is seconds as a DOUBLE, with the fraction; epoch_ms(ts)
    # and epoch_us(ts) are BIGINT milliseconds and microseconds.
    back = s.sql(
        "SELECT epoch(ts) AS s, epoch_ms(ts) AS ms, epoch_us(ts) AS us"
        " FROM (SELECT epoch_ms(unix_ms) AS ts FROM events) AS e ORDER BY ms"
    )
    for row in back.to_arrow().to_pylist():
        print(row)

# pandas-shaped: komira.to_datetime(series, unit=...) reads an integer as a
# count of seconds ("s"), milliseconds ("ms"), microseconds or nanoseconds.
df = komira.read_csv("events.csv")
df["ts"] = komira.to_datetime(df["unix_s"], unit="s")
df["ts_ms"] = komira.to_datetime(df["unix_ms"], unit="ms")
print(df.dtypes)
for row in df.sort_values("unix_s").materialize().to_arrow().to_pylist():
    print(row["ts"], row["ts_ms"])
```

Output:

<!-- include expected_output.txt -->
```text
1788220800 2026-09-01 00:00:00 1788220800123 2026-09-01 00:00:00.123000
1788224461 2026-09-01 01:01:01 1788224461500 2026-09-01 01:01:01.500000
1788438896 2026-09-03 12:34:56 1788438896007 2026-09-03 12:34:56.007000
{'s': 1788220800.123, 'ms': 1788220800123, 'us': 1788220800123000}
{'s': 1788224461.5, 'ms': 1788224461500, 'us': 1788224461500000}
{'s': 1788438896.007, 'ms': 1788438896007, 'us': 1788438896007000}
{'unix_s': 'int64', 'unix_ms': 'int64', 'ts': 'timestamp_us', 'ts_ms': 'timestamp_us'}
2026-09-01 00:00:00 2026-09-01 00:00:00.123000
2026-09-01 01:01:01 2026-09-01 01:01:01.500000
2026-09-03 12:34:56 2026-09-03 12:34:56.007000
```

## Notes

- `make_timestamp(n)` reads `n` as microseconds since the Unix epoch, and `epoch_ms(n)` (the same as `make_timestamp_ms(n)`) reads milliseconds; both answer a TIMESTAMP, which Python receives as a `datetime.datetime`. The argument must be an integer: a DOUBLE is refused by name, so cast it to BIGINT first.
- `epoch_ms` has two overloads, as in DuckDB: of a BIGINT it makes a TIMESTAMP, of a TIMESTAMP or DATE it answers BIGINT milliseconds. `epoch(x)` is DOUBLE seconds, with the fraction of a second, and `epoch_us(x)` BIGINT microseconds. Before 1970 the counts are negative, and `epoch_ms` drops the sub-millisecond part toward zero: `epoch_ms(TIMESTAMP '1969-12-31 23:59:59.9995')` is 0 and `epoch_us` of it is -500. A NULL stays NULL.
- A multiplication that does not fit in 64 bits raises an overflow error; it does not wrap. So does `komira.to_datetime` of a count of seconds too large for a microsecond timestamp.
- `komira.to_datetime(s, unit=...)` takes a Series of integers, with `unit` `"s"`, `"ms"`, `"us"` or `"ns"` (pandas' default). `"s"`, `"ms"` and `"us"` give `timestamp_us` and `"ns"` gives `timestamp_ns`, where pandas gives `datetime64[ns]` for each. Text and its `format=`, floats, `utc=True` and `errors="coerce"` are refused by name.
- `date_part('epoch', ts)` and `EXTRACT(epoch FROM ts)` are the same as `epoch(ts)`.
- Not served yet: `to_timestamp(n)`, which in DuckDB answers a TIMESTAMP WITH TIME ZONE and waits on time-zone support (komira-ai/komira#2342); `epoch_ns(ts)`; `CAST(ts AS BIGINT)`. Each is refused by name.

## Related

- How do I filter rows by a date range? (rank 83, works)
- How do I split events into sessions by time gap? (rank 84, works)
- How do I group by month or week? (rank 80, works; no page yet)
- How do I fill gaps in a time series so every date is present? (rank 81, gap; no page yet)
