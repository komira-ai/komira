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
