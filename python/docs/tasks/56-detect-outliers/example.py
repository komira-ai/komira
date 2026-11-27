from pathlib import Path

import komira

# Ten order totals; two of them are far from the rest.
totals = [10, 12, 11, 13, 12, 11, 10, 95, 12, -40]
Path("orders.csv").write_text(
    "id,total\n" + "".join(f"{i},{t}\n" for i, t in enumerate(totals, 1))
)

# A z-score rule: flag a value more than 1.5 standard deviations from the mean.
# The standard deviation is written as sqrt(avg(x*x) - avg(x)^2), the population form.
query = """
WITH stats AS (
    SELECT avg(total) AS mean,
           sqrt(avg(total * total) - avg(total) * avg(total)) AS sd
    FROM orders
)
SELECT id, total, (total - mean) / sd AS z
FROM orders, stats
WHERE abs(total - mean) > 1.5 * sd
ORDER BY id
"""

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    for row in s.sql(query).to_arrow().to_pylist():
        print(f"id={row['id']} total={row['total']} z={row['z']:.2f}")
