from pathlib import Path

import komira

Path("orders.csv").write_text(
    "order_id,customer,region,amount\n"
    "1,Ana,east,120\n"
    "2,Bo,west,80\n"
    "3,Ana,east,45\n"
    "4,Cy,north,200\n"
    "5,Bo,west,150\n"
)

# SQL: the columns you want in SELECT, the condition in WHERE.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    big = s.sql(
        "SELECT order_id, customer, amount FROM orders"
        " WHERE amount > 100 ORDER BY order_id"
    )
    print(big.to_arrow().to_pylist())

    # Several conditions, and a list of allowed values.
    east_or_north = s.sql(
        "SELECT order_id, region FROM orders"
        " WHERE amount >= 45 AND region IN ('east', 'north') ORDER BY order_id"
    )
    print(east_or_north.to_arrow().to_pylist())

# pandas-shaped: a boolean Series picks rows, a list of names picks columns.
df = komira.read_csv("orders.csv")
big = df[df["amount"] > 100][["order_id", "customer", "amount"]]
print(big.sort_values("order_id").materialize().to_arrow().to_pylist())

west_big = df[(df["region"] == "west") & (df["amount"] > 100)][["order_id"]]
print(west_big.materialize().to_arrow().to_pylist())
