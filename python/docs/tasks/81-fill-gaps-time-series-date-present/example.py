from pathlib import Path

import komira

Path("visits.csv").write_text(
    "day,page\n"
    "2024-01-02,home\n"
    "2024-01-02,about\n"
    "2024-01-03,home\n"
    "2024-01-06,pricing\n"
)

with komira.Session() as s:
    s.register_csv("visits", "visits.csv")

    # generate_series gives one row per day from the first date to the last,
    # both included. LEFT JOIN the counts onto it: a day without visits has
    # no count (NULL), and COALESCE makes it 0.
    rows = s.sql(
        "SELECT t.d, COALESCE(v.n, 0) AS n"
        " FROM generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY) AS t(d)"
        " LEFT JOIN (SELECT day, count(*) AS n FROM visits GROUP BY day) AS v"
        " ON v.day = t.d"
        " ORDER BY t.d"
    )
    for r in rows.to_arrow().to_pylist():
        print(r["d"].date(), r["n"])

    # range stops before the end: the Mondays of January 2024.
    weeks = s.sql(
        "SELECT * FROM range(DATE '2024-01-01', DATE '2024-02-01', INTERVAL '1' WEEK)"
    )
    print([r["range"].date().isoformat() for r in weeks.to_arrow().to_pylist()])
