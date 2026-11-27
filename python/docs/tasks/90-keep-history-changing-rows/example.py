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
