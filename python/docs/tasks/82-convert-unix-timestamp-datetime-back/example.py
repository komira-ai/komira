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
