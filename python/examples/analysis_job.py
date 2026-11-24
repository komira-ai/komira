"""A small analysis job: read a Parquet file and a CSV file, join them, group,
rank inside each group with window functions, keep the top customers and write
the result to Parquet.

    python analysis_job.py <directory>

The program writes its two inputs into <directory> (`orders.parquet` and
`customers.csv`), runs the job with komira, writes the answer to
`top_customers.parquet` there, and prints it. The amounts are whole cents
(BIGINT), so every sum is exact and the same SQL run by any engine that follows
DuckDB gives the same rows.
`python/tests/test_analysis_job.py` runs this file from the installed wheel and
compares every answer with DuckDB's.
"""

import csv
import os
import sys

import komira
import pyarrow as pa
import pyarrow.parquet as pq

REGIONS = ("east", "north", "west")

CUSTOMERS = 12

ORDERS = 240


def write_inputs(directory):
    """Writes `orders.parquet` and `customers.csv` into `directory`; returns
    their paths.

    The orders name customers 1 to 14 and the CSV file lists 1 to 12, so the
    inner join drops the orders of customers 13 and 14; one order in five has
    quantity 0 and the job's filter drops it.
    """
    orders = os.path.join(directory, "orders.parquet")
    customers = os.path.join(directory, "customers.csv")
    pq.write_table(
        pa.table(
            {
                "order_id": pa.array(range(1, ORDERS + 1), pa.int64()),
                "customer_id": pa.array([1 + (i * 5 + i // 3) % 14 for i in range(ORDERS)], pa.int64()),
                "amount_cents": pa.array([25 * (1 + (i * 37) % 400) for i in range(ORDERS)], pa.int64()),
                "quantity": pa.array([i % 5 for i in range(ORDERS)], pa.int64()),
            }
        ),
        orders,
    )
    with open(customers, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["id", "name", "region"])
        for i in range(1, CUSTOMERS + 1):
            w.writerow([i, "customer_{:02d}".format(i), REGIONS[i % len(REGIONS)]])
    return orders, customers


# What each customer spent: the orders (the Parquet table `orders`) joined to
# the customers (the CSV file) on the customer, orders with quantity 0
# dropped, summed per customer.
SPEND = """
    SELECT c.region AS region, c.name AS customer,
           count(*) AS n_orders, sum(o.amount_cents) AS sum_cents
    FROM orders o JOIN cust c ON o.customer_id = c.id
    WHERE o.quantity > 0
    GROUP BY c.region, c.name
"""

# The sums as BIGINT: an integer SUM is DECIMAL(38, 0) in komira and HUGEINT in
# DuckDB, and the cast is a step of its own because the engine does not serve a
# call that wraps an aggregate.
SPEND_CTES = (
    "sums AS (" + SPEND + "), "
    "spend AS (SELECT region, customer, n_orders, CAST(sum_cents AS BIGINT) AS total_cents FROM sums)"
)

# Each customer's place among its region's customers by total, and the
# region's running total down that order.
RANKED = """
    SELECT region, customer, n_orders, total_cents,
           row_number() OVER (PARTITION BY region ORDER BY total_cents DESC, customer) AS place,
           sum(total_cents) OVER (PARTITION BY region ORDER BY total_cents DESC, customer) AS running_total
    FROM spend
"""

# The top two customers of each region.
TOP_PER_REGION = (
    "WITH cust AS (SELECT id, name, region FROM read_csv('{customers}')), "
    + SPEND_CTES + ", ranked AS (" + RANKED + ") "
    "SELECT region, customer, n_orders, total_cents, place, running_total "
    "FROM ranked WHERE place <= 2 ORDER BY region, place"
)

# The three customers that spent the most, over all regions.
TOP_OVERALL = (
    "WITH cust AS (SELECT id, name, region FROM read_csv('{customers}')), "
    + SPEND_CTES + " "
    "SELECT customer, region, total_cents FROM spend ORDER BY total_cents DESC, customer LIMIT 3"
)

# The result as written: the per-region top two, to Parquet.
WRITE_RESULT = "COPY (" + TOP_PER_REGION + ") TO '{output}' (FORMAT parquet)"


def run(directory):
    """Runs the job with komira over the inputs in `directory`; returns
    {"per_region": rows, "overall": rows, "written": rows}, each a list of
    dicts. `written` is read back from the Parquet file the job wrote."""
    orders, customers = write_inputs(directory)
    output = os.path.join(directory, "top_customers.parquet")
    with komira.Session() as s:
        s.register_parquet("orders", orders)
        per_region = s.sql(TOP_PER_REGION.format(customers=customers)).to_arrow().to_pylist()
        overall = s.sql(TOP_OVERALL.format(customers=customers)).to_arrow().to_pylist()
        count = s.sql(WRITE_RESULT.format(customers=customers, output=output)).to_arrow().to_pylist()
    assert count == [{"Count": len(per_region)}], "the write reported {}, not {} rows".format(count, len(per_region))
    return {"per_region": per_region, "overall": overall, "written": pq.read_table(output).to_pylist()}


def main(argv):
    if len(argv) != 2:
        raise SystemExit("usage: analysis_job.py <directory>")
    answer = run(argv[1])
    print("top two customers of each region:")
    for row in answer["per_region"]:
        print(row)
    print("top three customers overall:")
    for row in answer["overall"]:
        print(row)


if __name__ == "__main__":
    main(sys.argv)
