# How do I process a CSV that does not fit in memory?

Register the file and ask for the answer in SQL: the filter and the group-by run in the engine and only the small answer reaches Python, and a big answer is read batch by batch with `to_reader()`. Memory use on a file larger than memory was not measured here.

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
Lima 1334 39353
Oslo 1333 39330
Pune 1333 39317
1000 44500
[{'city': 'Lima', 'n': 1334}, {'city': 'Oslo', 'n': 1333}, {'city': 'Pune', 'n': 1333}]
```

## Notes

- `register_csv` and `komira.read_csv` do not load the file: they read the start of it to infer the columns, and every query reads the file again. Put the filter and the aggregate in the query, so that only the answer reaches Python.
- `to_arrow()` and `to_pandas()` hold the whole answer in memory; `to_reader()` gives a `pyarrow.RecordBatchReader` that reads batches as they are asked for. A result is read once.
- `komira.Session(memory_limit=<bytes>)` caps what a query may use: a query that needs more raises `MemoryLimitError` instead of exhausting the machine, and one the engine can run in less (a `GROUP BY` that spills) does not raise.
- The loop pandas spells `pd.read_csv(path, chunksize=n)` is not there: `komira.read_csv` has no `chunksize` (komira-ai/komira#2369). `probe_chunksize.py` beside this page tries it and must fail with the line in `probe_chunksize.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it. Today the way to work through a file piece by piece is the query, or `to_reader()` on its answer.
- The example writes a 5000-row file so that it runs in the check; the same code is what you would write for a larger file.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I write a table to a CSV file?](../11-write-table-csv-file/page.md) (rank 11, partial)
- [How do I write a table to Parquet?](../27-write-table-parquet/page.md) (rank 27, partial)
- How do I run SQL on a CSV or Parquet file (or a DataFrame)? (rank 37, partial; no page yet)
- [How do I convert a folder of CSV files to Parquet?](../99-convert-folder-csv-files-parquet/page.md) (rank 99, works)
