from pathlib import Path

import komira

Path("orders.csv").write_text(
    "order_id,customer,region,amount\n"
    "1,Ana,east,120\n"
    "2,Bo,west,80\n"
    "3,Ana,east,45\n"
    "4,Cy,north,200\n"
    "5,Bo,west,150\n"
    "6,Cy,north,60\n"
)

# SQL: every aggregate is a select item, and AS names its output column.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    total = s.sql(
        "SELECT count(*) AS orders, sum(amount) AS revenue,"
        " min(amount) AS smallest, max(amount) AS largest,"
        " count(DISTINCT customer) AS customers FROM orders"
    )
    print(total.to_arrow().to_pylist())

    # The same per group: the key columns, then the named aggregates.
    by_region = s.sql(
        "SELECT region, count(*) AS orders, sum(amount) AS revenue, max(amount) AS largest"
        " FROM orders GROUP BY region ORDER BY region"
    )
    print(by_region.to_arrow().to_pylist())

# pandas-shaped: agg(name=("column", "function")) names each output.
df = komira.read_csv("orders.csv")
stats = df.groupby("region").agg(
    orders=("order_id", "count"),
    revenue=("amount", "sum"),
    largest=("amount", "max"),
)
print(stats.sort_values("region").materialize().to_arrow().to_pylist())

# Without groupby, agg reduces the whole frame to one row.
print(df.agg(revenue=("amount", "sum"), largest=("amount", "max")).materialize().to_arrow().to_pylist())
