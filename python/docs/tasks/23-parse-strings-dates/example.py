from pathlib import Path

import pyarrow as pa
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

# Any other format: strptime(text, format) parses the text in SQL. The format
# is a constant string of % directives and the result is a timestamp.
Path("us_orders.csv").write_text(
    "id,shipped\n"
    "1,09/15/2026\n"
    "2,10/20/2026\n"
    "3,12/31/2026\n"
)
with komira.Session() as s:
    s.register_csv("us_orders", "us_orders.csv")
    result = s.sql(
        "SELECT id, strptime(shipped, '%m/%d/%Y') AS shipped"
        " FROM us_orders ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())

# ISO text held as a string column: CAST gives a date, TRY_CAST gives NULL for
# text that is not a date (a column that mixes dates with "unknown" is text).
Path("text_dates.csv").write_text(
    "id,shipped\n"
    "1,2026-09-15\n"
    "2,unknown\n"
    "3,2026-12-31\n"
)
with komira.Session() as s:
    s.register_csv("text_dates", "text_dates.csv")
    result = s.sql(
        "SELECT id, TRY_CAST(shipped AS DATE) AS shipped"
        " FROM text_dates ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())
    s.register_csv("text_ok", "orders.csv", all_varchar=True)
    result = s.sql(
        "SELECT id, CAST(shipped AS DATE) AS shipped FROM text_ok ORDER BY id"
    ).to_arrow()
    print(result.schema.field("shipped").type)
    print(result.to_pylist())

# pandas-shaped: astype("date32") on a string column parses it like CAST.
pq.write_table(
    pa.table({"id": [1, 2], "shipped": ["2026-09-15", "2026-10-01"]}),
    "strings.parquet",
)
df = komira.read_parquet("strings.parquet")
typed = df.astype({"shipped": "date32"}).sort_values("id").materialize().to_arrow()
print(typed.schema.field("shipped").type)
print(typed.to_pylist())
