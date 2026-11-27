from pathlib import Path

import komira
from komira import pl

Path("tickets.csv").write_text(
    "team,priority\n"
    "web,high\n"
    "web,low\n"
    "web,high\n"
    "api,low\n"
    "api,low\n"
    "data,high\n"
)

# SQL: one count per value of the second column, one row per value of the first.
# A pair that never occurs counts 0.
with komira.Session() as s:
    s.register_csv("tickets", "tickets.csv")
    table = s.sql(
        "SELECT team,"
        " count(CASE WHEN priority = 'high' THEN 1 END) AS high,"
        " count(CASE WHEN priority = 'low' THEN 1 END) AS low"
        " FROM tickets GROUP BY team ORDER BY team"
    )
    print(table.to_arrow().to_pylist())

    # The long form: one row per pair that occurs.
    pairs = s.sql(
        "SELECT team, priority, count(*) AS n FROM tickets"
        " GROUP BY team, priority ORDER BY team, priority"
    )
    print(pairs.to_arrow().to_pylist())

# pandas-shaped: the long form, one row per pair.
df = komira.read_csv("tickets.csv")
pairs = df.groupby(["team", "priority"]).agg(n=("priority", "count"))
print(pairs.sort_values(["team", "priority"]).materialize().to_arrow().to_pylist())

# polars-shaped: the wide form with when/then/otherwise.
high = pl.when(pl.col("priority") == "high").then(1).otherwise(0)
low = pl.when(pl.col("priority") == "low").then(1).otherwise(0)
wide = (
    pl.scan_csv("tickets.csv")
    .group_by("team")
    .agg(high.sum().alias("high"), low.sum().alias("low"))
    .sort("team")
    .collect()
)
print(wide.to_arrow().to_pylist())
