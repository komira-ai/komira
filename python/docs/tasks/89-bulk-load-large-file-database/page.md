# How do I bulk-load a large file into a database?

Read the file with komira (`register_csv` and SQL), take the answer as a stream of Arrow record batches with `to_reader()`, and bulk-insert each batch with the database's own driver; `sqlite3` ships with Python.

<!-- include example.py -->
```python
import sqlite3
from pathlib import Path

import komira

# A CSV file of 12,000 sales, standing in for a file too big to hold as
# Python objects. A cents of 0 marks a test row that must not be loaded.
regions = ["north", "south", "east", "west"]
with Path("sales.csv").open("w") as f:
    f.write("id,region,cents\n")
    for i in range(1, 12001):
        f.write(f"{i},{regions[i % 4]},{(i * 37) % 1000}\n")

db = sqlite3.connect("sales.db")
db.execute("CREATE TABLE sales (id INTEGER PRIMARY KEY, region TEXT, cents INTEGER)")

with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    print(s.sql("SELECT count(*) AS n FROM sales").to_arrow().to_pylist())
    # komira reads the file and drops the test rows; the answer arrives as
    # Arrow record batches, and each batch is bulk-inserted before the next.
    reader = s.sql("SELECT id, region, cents FROM sales WHERE cents > 0").to_reader()
    for batch in reader:
        db.executemany("INSERT INTO sales VALUES (:id, :region, :cents)", batch.to_pylist())
db.commit()

print(db.execute("SELECT count(*), sum(cents) FROM sales").fetchone())
for row in db.execute("SELECT region, count(*), sum(cents) FROM sales GROUP BY region ORDER BY region"):
    print(row)
db.close()
```

Output:

<!-- include expected_output.txt -->
```text
[{'n': 12000}]
(11988, 5994000)
('east', 3000, 1500000)
('north', 2988, 1494000)
('south', 3000, 1497000)
('west', 3000, 1503000)
```

## Notes

- komira reads and filters the file; the database's driver does the load. `to_reader()` gives the answer as Arrow record batches, so the Python side holds the rows of one batch at a time, where `to_arrow()` would hold them all. The file here has 12,000 rows to stay small; the shape is the same for a larger one.
- Each batch is inserted with one `executemany`, inside the transaction the driver opens on the first insert; the `commit` at the end makes the load one transaction.
- komira has no database connector yet, so the write goes through the driver: komira-ai/komira#2335 tracks writing to a database table from komira itself.
- komira cannot yet load the file itself: `probe_native_attach.py` beside this page tries `ATTACH` through komira and must fail with the line in `probe_native_attach.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.

### Postgres

The same shape with `psycopg` (`pip install psycopg`) and a Postgres server, which streams each batch's rows through `COPY`; `reader` is the Arrow reader of the program above.

<!-- not-tested: needs a Postgres server, which the check does not have -->
```python
import psycopg

with psycopg.connect("dbname=app") as conn:
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE sales (id bigint PRIMARY KEY, region text, cents bigint)")
        with cur.copy("COPY sales (id, region, cents) FROM STDIN") as copy:
            for batch in reader:
                for row in batch.to_pylist():
                    copy.write_row((row["id"], row["region"], row["cents"]))
```

## Related

- How do I process a CSV that does not fit in memory? (rank 28, partial; no page yet)
- How do I read a JSON file and write the records to a database? (rank 22, partial)
- How do I append rows to an existing database table? (rank 88, gap; no page yet)
- How do I write a DataFrame to a database table? (rank 21, gap; no page yet)
