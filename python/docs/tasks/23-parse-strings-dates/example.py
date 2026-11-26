from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

import komira

# ISO text ("2026-09-15") is read as a date by the CSV reader itself.
Path("orders.csv").write_text(
    "id,shipped\n"
    "1,2026-09-15\n"
    "2,2026-10-01\n"
    "3,2026-12-31\n"
)
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    result = s.sql(
        "SELECT id, shipped, month(shipped) AS month,"
        " date_diff('day', DATE '2026-09-01', shipped) AS days"
        " FROM orders WHERE shipped >= DATE '2026-10-01' ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())

# Any other format: parse the text with pyarrow, then give komira the dates.
text = pa.table({"id": [1, 2, 3], "shipped": ["09/15/2026", "10/20/2026", "12/31/2026"]})
parsed = pc.strptime(text["shipped"], format="%m/%d/%Y", unit="s").cast(pa.date32())
pq.write_table(text.set_column(1, "shipped", parsed), "us_orders.parquet")
with komira.Session() as s:
    s.register_parquet("us_orders", "us_orders.parquet")
    result = s.sql(
        "SELECT id, shipped, year(shipped) AS year FROM us_orders"
        " WHERE shipped < DATE '2026-12-01' ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())
