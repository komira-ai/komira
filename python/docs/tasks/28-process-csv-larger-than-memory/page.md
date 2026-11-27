# How do I process a CSV that does not fit in memory?

Register the file and ask for the answer in SQL: the filter and the group-by run in the engine and only the small answer reaches Python, and a big answer is read batch by batch with `to_reader()`. Or loop over the file as pandas does, `for chunk in komira.read_csv(path, chunksize=n)`: each chunk is a `pyarrow.Table` of at most `n` rows, not a komira `DataFrame`, so the work on it is yours, in Python or pyarrow. Memory use on a file larger than memory was not measured here.

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

# Or the pandas loop: read_csv(chunksize=n) reads the file as it is asked for,
# each chunk a pyarrow.Table of at most n rows; the totals kept across the
# chunks are the ones the query above gave.
chunks = 0
n = {}
total = {}
for chunk in komira.read_csv("sales.csv", chunksize=1000):
    chunks += 1
    for city, amount in zip(chunk["city"].to_pylist(), chunk["amount"].to_pylist()):
        if amount >= 10:
            n[city] = n.get(city, 0) + 1
            total[city] = total.get(city, 0) + amount
print(chunks, "chunks")
for city in sorted(n):
    print(city, n[city], total[city])

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
5 chunks
Lima 1334 39353
Oslo 1333 39330
Pune 1333 39317
[{'city': 'Lima', 'n': 1334}, {'city': 'Oslo', 'n': 1333}, {'city': 'Pune', 'n': 1333}]
```

## Notes

- `register_csv` and `komira.read_csv` do not load the file: they read the start of it to infer the columns, and every query reads the file again. Put the filter and the aggregate in the query, so that only the answer reaches Python.
- `to_arrow()` and `to_pandas()` hold the whole answer in memory; `to_reader()` gives a `pyarrow.RecordBatchReader` that reads batches as they are asked for. A result is read once.
- `komira.Session(memory_limit=<bytes>)` caps what a query may use: a query that needs more raises `MemoryLimitError` instead of exhausting the machine, and one the engine can run in less (a `GROUP BY` that spills) does not raise.
- `komira.read_csv(path, chunksize=n)` is pandas' loop (pandas documentation, "Iterating through files chunk by chunk"): it returns a reader whose chunks have `n` rows each, the last one the rest, read from the file as the loop asks for them, so the loop holds one chunk and a block of the file at a time, not the whole file (`get_chunk()` with neither a size nor a `chunksize` reads the rest of the file at once). `iterator=True` and `reader.get_chunk(size)` take the next `size` rows; `close()`, or a `with` block, releases the file early. The column names and types are inferred from the start of the file, as `read_csv` infers them; a later cell that does not fit its column's type is NULL, as the engine reads it, and a malformed row raises `KomiraError` when the loop reaches it. A chunk is a `pyarrow.Table` (`chunk.to_pandas()` with pandas installed), not a komira `DataFrame`, which is a plan over a file and holds no rows: that is the part of this task komira does not do, so a chunk's filter and sums run in Python or pyarrow, not in the engine.
- The example writes a 5000-row file so that it runs in the check; the same code is what you would write for a larger file.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I write a table to a CSV file?](../11-write-table-csv-file/page.md) (rank 11, partial)
- [How do I write a table to Parquet?](../27-write-table-parquet/page.md) (rank 27, partial)
- [How do I run SQL on a CSV or Parquet file (or a DataFrame)?](../37-run-sql-csv-parquet-file/page.md) (rank 37, partial)
- [How do I convert a folder of CSV files to Parquet?](../99-convert-folder-csv-files-parquet/page.md) (rank 99, works)
