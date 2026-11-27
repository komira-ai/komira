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
