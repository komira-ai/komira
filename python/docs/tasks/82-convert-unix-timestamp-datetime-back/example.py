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
