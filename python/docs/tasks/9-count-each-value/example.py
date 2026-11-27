from pathlib import Path

import komira
import komira.pl as kpl

Path("visits.csv").write_text(
    "visit_id,city\n"
    "1,Oslo\n"
    "2,Lima\n"
    "3,Oslo\n"
    "4,Pune\n"
    "5,Lima\n"
    "6,Oslo\n"
    "7,Rome\n"
)

# SQL: GROUP BY the column, count(*) the rows. Pune and Rome both appear once,
# so the city is a second sort key and the order is fixed.
with komira.Session() as s:
    s.register_csv("visits", "visits.csv")
    counts = s.sql(
        "SELECT city, count(*) AS n FROM visits"
        " GROUP BY city ORDER BY n DESC, city"
    )
    print(counts.to_arrow().to_pylist())

# pandas-shaped: groupby(...).size() counts the rows of each group in a
# column named size.
df = komira.read_csv("visits.csv")
sizes = df.groupby("city").size().sort_values(["size", "city"], ascending=[False, True])
print(sizes.materialize().to_arrow().to_pylist())

# polars-shaped: group_by(...).len() counts the rows in a column named len.
lf = kpl.scan_csv("visits.csv")
lens = lf.group_by("city").len().sort("len", "city", descending=[True, False])
print(lens.collect().to_arrow().to_pylist())

# pandas' value_counts is refused, and the message says what to write.
try:
    df["city"].value_counts()
except AttributeError as e:
    print(e)
