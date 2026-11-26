from pathlib import Path

import komira

# Four small tables: orders point at customers and products, customers at regions.
Path("orders.csv").write_text(
    "order_id,customer_id,product_id,qty\n"
    "1,1,10,2\n"
    "2,2,11,1\n"
    "3,1,11,3\n"
    "4,3,10,1\n"
)
Path("customers.csv").write_text("customer_id,name,region_id\n1,Ana,100\n2,Bo,200\n3,Cy,100\n")
Path("products.csv").write_text("product_id,product\n10,pen\n11,ink\n")
Path("regions.csv").write_text("region_id,region\n100,north\n200,south\n")

with komira.Session() as s:
    # SQL: one JOIN ... ON per extra table, each joined to a table already named.
    for name in ("orders", "customers", "products", "regions"):
        s.register_csv(name, f"{name}.csv")
    rows = s.sql(
        "SELECT order_id, name, product, region, qty"
        " FROM orders AS o"
        " JOIN customers AS c ON o.customer_id = c.customer_id"
        " JOIN products AS p ON o.product_id = p.product_id"
        " JOIN regions AS r ON c.region_id = r.region_id"
        " ORDER BY order_id"
    )
    for row in rows.to_arrow().to_pylist():
        print(row)

# pandas-shaped: chain merge calls, each on the key the two sides share.
joined = (
    komira.read_csv("orders.csv")
    .merge(komira.read_csv("customers.csv"), on="customer_id")
    .merge(komira.read_csv("products.csv"), on="product_id")
    .merge(komira.read_csv("regions.csv"), on="region_id")
)
out = joined[["order_id", "name", "product", "region", "qty"]]
print(out.sort_values("order_id").materialize().to_arrow().to_pylist())
