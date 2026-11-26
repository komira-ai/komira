# How do I write a table to a CSV file?

Run `COPY (query) TO 'out.csv' (FORMAT csv, HEADER true)` through a `komira.Session`, or run a frame and write its Arrow table with `pyarrow.csv.write_csv`.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import pyarrow.csv as pacsv

Path("sales.csv").write_text("id,region,qty,amount\n1,north,2,2.5\n2,south,5,\n3,north,3,4.5\n4,east,1,1.0\n")

# SQL: COPY writes a query's result to a file and answers the row count.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    written = s.sql(
        "COPY (SELECT id, region, amount FROM sales WHERE region <> 'east' ORDER BY id)"
        " TO 'out.csv' (FORMAT csv, HEADER true)"
    ).to_arrow()
print("rows written:", written.column("Count")[0].as_py())
print(Path("out.csv").read_text(), end="")

# The pandas-shaped frame: run it, then write the Arrow table with pyarrow.
df = komira.read_csv("sales.csv")
totals = df.groupby("region", as_index=False)["qty"].sum().sort_values("region")
pacsv.write_csv(totals.materialize().to_arrow(), "totals.csv")
print(Path("totals.csv").read_text(), end="")
```

Output:

<!-- include expected_output.txt -->
```text
rows written: 3
id,region,amount
1,north,2.5
2,south,
3,north,4.5
"region","qty"
"east",1
"north",5
"south",5
```

## Notes

- `COPY ... TO` writes the bytes DuckDB's `COPY` writes for the same rows: a header row, `,` between cells, NULL as an empty cell, a string quoted only when it needs it. It answers one row, `Count`, the rows written. The write is all or nothing and replaces an existing file.
- The destination is a local path. A path ending in `.csv` needs no `FORMAT`; a name with no known extension is refused by name. A `.gz` or `.zst` name, or `COMPRESSION gzip` or `zstd`, writes a compressed file.
- komira's frames have no writer of their own: `df.to_csv(...)` on the pandas-shaped frame and `lf.sink_csv(...)` on the polars-shaped one are not there yet (komira-ai/komira#2372). `probe_frame_to_csv.py` and `probe_lazyframe_sink_csv.py` beside this page try them and must fail with the lines in their `.error.txt` files. The day one runs, this page's check goes red, and the page and the catalogue status change with it.
- The CSV options of `COPY` are only `FORMAT`, `COMPRESSION`, `COMPRESSION_LEVEL` and `HEADER`: a delimiter, quote character or NULL text option is refused by name (komira-ai/komira#2374). `HEADER` written bare, without `true`, is a syntax error today: komira-ai/komira#2322.
- pyarrow's `write_csv` quotes the header and every string cell, as the second file shows; `COPY` quotes a string only when it needs it.
- `HEADER false` is refused, since the writer always writes the header row.
- A partitioned write (`PARTITION_BY`) is komira-ai/komira#2346; writing to `s3://`, `gs://` or `az://` is komira-ai/komira#2337.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- How do I write a table to Parquet? (rank 27, partial; no page yet)
- How do I turn a query result into pandas, polars or Arrow? (rank 33, works; no page yet)
- How do I write a dataset partitioned by a column? (rank 97, gap; no page yet)
