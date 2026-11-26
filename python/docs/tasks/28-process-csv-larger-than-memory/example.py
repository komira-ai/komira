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

# The pandas-shaped frame is lazy too: the filter and the group-by are one query.
df = komira.read_csv("sales.csv")
by_city = df[df["amount"] >= 10].groupby("city").agg(n=("id", "count")).sort_values("city")
print(by_city.materialize().to_arrow().to_pylist())
