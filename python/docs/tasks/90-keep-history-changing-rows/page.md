# How do I keep history of changing rows (slowly changing dimension)?

Build the history rows in SQL with komira (`lag` finds each change, `lead` gives each version its end day), take them as Arrow, and store them with the database's own driver; `sqlite3` ships with Python.

<!-- include example.py -->
```python
import sqlite3
from pathlib import Path

import komira

# A log of daily snapshots: the tier each customer was on, as the day's
# export saw it (days are YYYYMMDD integers). A customer who has not changed
# tier appears again with the same tier.
Path("snapshots.csv").write_text(
    "customer,tier,day_key\n"
    "1,1,20260901\n"
    "1,1,20260902\n"
    "1,2,20260903\n"
    "1,2,20260904\n"
    "1,3,20260905\n"
    "2,1,20260901\n"
    "2,1,20260903\n"
    "3,2,20260902\n"
    "3,1,20260904\n"
)

# Each tier a customer was on becomes one row with the day it began and the
# day the next one began (NULL while it is the current one). lag() finds the
# days the tier changed; the WHERE keeps only those, and lead() then reads
# the start of the next kept row.
HISTORY = """
SELECT customer, tier, day_key AS valid_from,
       lead(day_key) OVER (PARTITION BY customer ORDER BY day_key) AS valid_to
FROM (
    SELECT customer, tier, day_key,
           lag(tier) OVER (PARTITION BY customer ORDER BY day_key) AS prev_tier
    FROM snapshots
) AS s
WHERE prev_tier IS NULL OR prev_tier <> tier
ORDER BY customer, valid_from
"""

with komira.Session() as s:
    s.register_csv("snapshots", "snapshots.csv")
    history = s.sql(HISTORY).to_arrow().to_pylist()

# komira hands back Arrow; sqlite3 stores the history table.
db = sqlite3.connect("history.db")
db.execute("CREATE TABLE tier_history (customer INTEGER, tier INTEGER, valid_from INTEGER, valid_to INTEGER)")
db.executemany("INSERT INTO tier_history VALUES (:customer, :tier, :valid_from, :valid_to)", history)
db.commit()

for row in db.execute("SELECT * FROM tier_history ORDER BY customer, valid_from"):
    print(row)
print("current:", db.execute("SELECT customer, tier FROM tier_history WHERE valid_to IS NULL ORDER BY customer").fetchall())
as_of = 20260903
print("as of", as_of, db.execute(
    "SELECT customer, tier FROM tier_history"
    " WHERE valid_from <= :d AND (valid_to IS NULL OR :d < valid_to) ORDER BY customer",
    {"d": as_of},
).fetchall())
db.close()
```

Output:

<!-- include expected_output.txt -->
```text
(1, 1, 20260901, 20260903)
(1, 2, 20260903, 20260905)
(1, 3, 20260905, None)
(2, 1, 20260901, None)
(3, 2, 20260902, 20260904)
(3, 1, 20260904, None)
current: [(1, 3), (2, 1), (3, 1)]
as of 20260903 [(1, 2), (2, 1), (3, 2)]
```

## Notes

- This is the type 2 form of a slowly changing dimension: one row per version of a customer, with the day it began (`valid_from`) and the day the next version began (`valid_to`, NULL for the current one). A point-in-time question is then a range test on those two columns, as the last line of the output shows.
- komira computes the versions from the whole snapshot log each run. `lag(tier)` is NULL on a customer's first snapshot and differs from `tier` where the tier changed; the `WHERE` keeps those rows only, and `lead(day_key)` over the kept rows is the start of the next version. The window functions are those of rank 77.
- komira cannot read the history table back from the database (komira-ai/komira#2334) or change it (komira-ai/komira#2335), so the history is rebuilt from the log rather than extended in place by closing the current row and adding a new one. The driver stores the result.
- komira cannot yet write the rows itself: `probe_native_update.py` beside this page tries `UPDATE` through komira and must fail with the line in `probe_native_update.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- The days are integers of the form YYYYMMDD, which sort and compare as days do. A DATE column cannot be the argument of `lag` or `lead` yet (the lowering refuses it with `LOWERING_WINDOW_UNSERVED`; integer, float and text columns are served), which is why the days are integers.

## Related

- How do I compare each row with the previous row (lag, lead, change)? (rank 77, works; no page yet)
- How do I upsert rows into a database table? (rank 85, gap; no page yet)
- How do I append rows to an existing database table? (rank 88, gap; no page yet)
- How do I read a JSON file and write the records to a database? (rank 22, partial)
- How do I compare two datasets and show the differences? (rank 70, works; no page yet)
