from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira

# A CSV file and a Parquet file to query.
Path("sales.csv").write_text(
    "id,region,amount\n"
    "1,east,120\n"
    "2,west,80\n"
    "3,east,45\n"
    "4,north,200\n"
    "5,west,150\n"
)
targets = pa.table({"region": ["east", "west", "north"], "target": [100, 100, 150]})
pq.write_table(targets, "targets.parquet")

with komira.Session() as s:
    # SQL straight on a file: the path in FROM, or read_csv / read_parquet.
    by_region = s.sql(
        "SELECT region, count(*) AS orders, max(amount) AS biggest, avg(amount) AS mean"
        " FROM 'sales.csv' GROUP BY region ORDER BY region"
    )
    for row in by_region.to_arrow().to_pylist():
        print(row)
    print(s.sql("SELECT * FROM read_parquet('targets.parquet') ORDER BY region").to_arrow().to_pylist())

    # Register the files as tables to join them.
    s.register_csv("sales", "sales.csv")
    s.register_parquet("targets", "targets.parquet")
    over = s.sql(
        "SELECT s.id AS id, s.region AS region, s.amount AS amount, t.target AS target"
        " FROM sales AS s JOIN targets AS t ON s.region = t.region"
        " WHERE s.amount > t.target ORDER BY s.id"
    )
    print(over.to_arrow().to_pylist())

    # A DataFrame is not a table yet: its rows go to a Parquet file first.
    df = komira.read_csv("sales.csv")
    big = df[df["amount"] > 100]
    pq.write_table(big.materialize().to_arrow(), "big.parquet")
    s.register_parquet("big", "big.parquet")
    print(s.sql("SELECT id, amount FROM big ORDER BY id").to_arrow().to_pylist())
