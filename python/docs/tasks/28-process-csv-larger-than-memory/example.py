from pathlib import Path

import komira

# A stand-in for a big file: 5000 sales rows, id,city,amount.
cities = ["Oslo", "Lima", "Pune"]
rows = (f"{i},{cities[i % 3]},{i % 50}\n" for i in range(1, 5001))
Path("sales.csv").write_text("id,city,amount\n" + "".join(rows))

with komira.Session() as s:
    # Every query reads the file, with the columns inferred at registration.
    s.register_csv("sales", "sales.csv")
    totals = s.sql(
        "SELECT city, count(*) AS n, sum(amount) AS total"
        " FROM sales WHERE amount >= 10 GROUP BY city ORDER BY city"
    )
    for row in totals.to_arrow().to_pylist():
        print(row["city"], row["n"], int(row["total"]))

    # A result too big to hold is read batch by batch.
    big = s.sql("SELECT id, amount FROM sales WHERE amount >= 40").to_reader()
    rows_seen = 0
    amount_sum = 0
    for batch in big:
        rows_seen += batch.num_rows
        amount_sum += sum(batch.column("amount").to_pylist())
    print(rows_seen, amount_sum)

# Or the pandas loop: read_csv(chunksize=n) reads the file as it is asked for,
# each chunk a pyarrow.Table of at most n rows; the totals kept across the
# chunks are the ones the query above gave.
chunks = 0
n = {}
total = {}
for chunk in komira.read_csv("sales.csv", chunksize=1000):
    chunks += 1
    for city, amount in zip(chunk["city"].to_pylist(), chunk["amount"].to_pylist()):
        if amount >= 10:
            n[city] = n.get(city, 0) + 1
            total[city] = total.get(city, 0) + amount
print(chunks, "chunks")
for city in sorted(n):
    print(city, n[city], total[city])

# The pandas-shaped frame is lazy too: the filter and the group-by are one query.
df = komira.read_csv("sales.csv")
by_city = df[df["amount"] >= 10].groupby("city").agg(n=("id", "count")).sort_values("city")
print(by_city.materialize().to_arrow().to_pylist())
