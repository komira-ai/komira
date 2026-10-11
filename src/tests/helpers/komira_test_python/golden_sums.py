"""An oracle: DuckDB sums each team's score in a checked-in CSV.

    golden_sums.py <output directory> <data directory>

Reads `scores.csv` (`team,score`) from the data directory and writes, under
the output directory, `sums.tsv` (one `team<TAB>sum` line per team, ordered
by team) and `summary/count.txt` (the number of rows read). The order is
fixed by `ORDER BY`, so two runs write the same bytes.
"""

import os
import sys

import duckdb

out, data = sys.argv[1], sys.argv[2]
con = duckdb.connect()
path = os.path.join(data, "scores.csv").replace("'", "''")
con.execute(
    "CREATE TABLE scores AS SELECT * FROM read_csv('{}', header = true, "
    "columns = {{'team': 'VARCHAR', 'score': 'BIGINT'}})".format(path)
)
sums = con.execute("SELECT team, SUM(score) FROM scores GROUP BY team ORDER BY team").fetchall()
count = con.execute("SELECT COUNT(*) FROM scores").fetchall()[0][0]
with open(os.path.join(out, "sums.tsv"), "w") as f:
    for team, total in sums:
        f.write("{}\t{}\n".format(team, total))
os.makedirs(os.path.join(out, "summary"))
with open(os.path.join(out, "summary", "count.txt"), "w") as f:
    f.write("{}\n".format(count))
