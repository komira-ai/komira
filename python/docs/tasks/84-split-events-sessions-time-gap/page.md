# How do I split events into sessions by time gap?

Order each user's events, flag the ones more than 30 minutes after the user's previous event with `date_diff` and `lag`, and number the sessions with a running `sum` of the flag.

<!-- include example.py -->
```python
import datetime as dt

import pyarrow as pa
import pyarrow.parquet as pq

import komira

# Events as (user, time), out of order. The times go into a Parquet file as
# a timestamp column: komira reads CSV datetimes as text, and date_diff
# needs timestamps.
events = [
    (1, dt.datetime(2026, 9, 1, 10, 30)),
    (1, dt.datetime(2026, 9, 1, 9, 0)),
    (1, dt.datetime(2026, 9, 1, 9, 25)),
    (1, dt.datetime(2026, 9, 1, 9, 10)),
    (1, dt.datetime(2026, 9, 1, 10, 31)),
    (2, dt.datetime(2026, 9, 1, 12, 0)),
    (2, dt.datetime(2026, 9, 1, 12, 30)),
    (2, dt.datetime(2026, 9, 1, 13, 0, 1)),
    (3, dt.datetime(2026, 9, 2, 8, 0)),
]
pq.write_table(
    pa.table(
        {
            "user_id": pa.array([u for u, _ in events], pa.int64()),
            "ts": pa.array([t for _, t in events], pa.timestamp("us")),
        }
    ),
    "events.parquet",
)

# A new session starts when the gap to the user's previous event is over 30
# minutes (1800 seconds). One CTE per step: seconds since a fixed start, the
# previous event's seconds, a 1/0 flag for "starts a session", and the running
# sum of the flag, which numbers the sessions.
SESSIONS = """
WITH a AS (
    SELECT user_id, ts, date_diff('second', TIMESTAMP '2026-09-01 00:00:00', ts) AS secs
    FROM events
), b AS (
    SELECT user_id, ts, secs,
           lag(secs) OVER (PARTITION BY user_id ORDER BY secs) AS prev_secs
    FROM a
), c AS (
    SELECT user_id, ts, secs,
           CASE WHEN prev_secs IS NULL OR secs - prev_secs > 1800 THEN 1 ELSE 0 END AS is_new
    FROM b
)
SELECT user_id, ts,
       sum(is_new) OVER (PARTITION BY user_id ORDER BY secs
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS session_no
FROM c
ORDER BY user_id, ts
"""

with komira.Session() as s:
    s.register_parquet("events", "events.parquet")
    for r in s.sql(SESSIONS).to_arrow().to_pylist():
        print(r["user_id"], r["ts"], r["session_no"])
```

Output:

<!-- include expected_output.txt -->
```text
1 2026-09-01 09:00:00 1
1 2026-09-01 09:10:00 1
1 2026-09-01 09:25:00 1
1 2026-09-01 10:30:00 2
1 2026-09-01 10:31:00 2
2 2026-09-01 12:00:00 1
2 2026-09-01 12:30:00 1
2 2026-09-01 13:00:01 2
3 2026-09-02 08:00:00 1
```

## Notes

- The gap is measured in seconds: `date_diff('second', <start>, ts)` counts whole seconds from a fixed start time, so a gap of exactly 1800 seconds stays in the session (user 2, 12:00:00 to 12:30:00) and 1801 seconds starts a new one (user 2, 13:00:01).
- Every step is its own CTE because a window function takes plain columns: `lag` reads `secs`, the `CASE` flag reads `prev_secs`, and the running `sum` reads the flag. `lag` runs on the seconds and not on `ts` itself, because komira's `lag` and `lead` serve integer, float and text columns and not timestamps yet.
- `ts - prev > INTERVAL '30 minutes'` is not served: komira has no interval value, only a constant date plus or minus an interval. Compare seconds as above.
- The timestamps must be a timestamp column, as Parquet and Arrow give. A CSV file with `YYYY-MM-DD HH:MM:SS` text reads that column as text, which `date_diff` refuses by name.
- The first event of each user has no previous event (`lag` is NULL), so it starts session 1.
- Sessions are numbered per user from 1. Sort the result with `ORDER BY`: rows come back in no promised order otherwise.
- The pandas-shaped frame has no `shift` or `diff` yet, so there is no frame form of this task today.

## Related

- How do I compare each row with the previous row (lag, lead, change)? (rank 77, works; no page yet)
- [How do I compute a running total per group?](../48-compute-running-total-per-group/page.md) (rank 48, works)
- [How do I rank rows within a group?](../49-rank-rows-within-group/page.md) (rank 49, works)
- How do I filter rows by a date range? (rank 83, works)
- How do I add days to a date or take the difference between dates? (rank 79, partial; no page yet)
- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
