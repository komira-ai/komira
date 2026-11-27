# How do I write a table to a CSV file?

Run `COPY (query) TO 'out.csv' (FORMAT csv, HEADER true)` through a `komira.Session` (with `DELIMITER`, `QUOTE`, `ESCAPE`, `NULL`, `HEADER false`, `DATEFORMAT` or `TIMESTAMPFORMAT` for another dialect), call `df.to_csv(path)` on the pandas-shaped frame, or run a frame and write its Arrow table with `pyarrow.csv.write_csv`.

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

# The CSV options DuckDB's COPY takes: a delimiter, no header line, a NULL text.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.sql(
        "COPY (SELECT id, region, amount FROM sales WHERE region <> 'east' ORDER BY id)"
        " TO 'out_semicolon.csv' (FORMAT csv, DELIMITER ';', HEADER false, NULL 'NA')"
    ).to_arrow()
print(Path("out_semicolon.csv").read_text(), end="")

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
1;north;2.5
2;south;NA
3;north;4.5
"region","qty"
"east",1
"north",5
"south",5
```

## Notes

- `COPY ... TO` writes the bytes DuckDB's `COPY` writes for the same rows: by default a header row, `,` between cells, NULL as an empty cell, a string quoted only when it needs it; the second file is the same rows with `DELIMITER ';'`, no header line and NULL written `NA`. It answers one row, `Count`, the rows written. The write is all or nothing and replaces an existing file.
- The destination is a local path. A path ending in `.csv` needs no `FORMAT`; a name with no known extension is refused by name. A `.gz` or `.zst` name, or `COMPRESSION gzip` or `zstd`, writes a compressed file.
- `df.to_csv(path)` on the pandas-shaped frame runs it once, writes the bytes `COPY ... TO` writes for the same rows, and returns `None`. A `.gz` or `.zst` name writes a compressed file (`compression="infer"`); `index` is accepted and changes nothing.
- The polars-shaped frame has no writer of its own yet: `lf.sink_csv(...)` is not there (komira-ai/komira#2372). `probe_lazyframe_sink_csv.py` beside this page tries it and must fail with the line in its `.error.txt` file. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- The CSV options of `COPY` are DuckDB's: `DELIMITER` (also `DELIM` and `SEP`; `'\t'` is a tab), `QUOTE`, `ESCAPE`, `NULL` (also `NULLSTR`), `HEADER true` or `false`, `DATEFORMAT` and `TIMESTAMPFORMAT` (strftime formats, as DuckDB writes them in UTC), with `FORMAT`, `COMPRESSION` and `COMPRESSION_LEVEL`. The file holds the bytes DuckDB writes for the same options: a cell is quoted when it holds the delimiter, the quote or a line break, or equals the NULL text, so with `NULL 'NA'` the string `NA` is quoted and the empty string is not. A value DuckDB refuses (a delimiter over 4 bytes, a quote of two characters, a quote inside the delimiter or the NULL text) is refused with DuckDB's reason; a delimiter of 2 to 4 bytes, which DuckDB writes only the first byte of, `%n` in a format, a `TIMESTAMP_MS` column under `TIMESTAMPFORMAT`, an option given twice and any other option (`FORCE_QUOTE`) are refused by name. The value of a CSV option is written quoted (`NULL 'NA'`). `HEADER` written bare, without `true`, is a syntax error today: komira-ai/komira#2322.
- pyarrow's `write_csv` quotes the header and every string cell, as the third file shows; `COPY` quotes a string only when it needs it.
- A partitioned write (`PARTITION_BY`) is komira-ai/komira#2346; writing to `s3://`, `gs://` or `az://` is komira-ai/komira#2337.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I write a table to Parquet?](../27-write-table-parquet/page.md) (rank 27, partial)
- [How do I turn a query result into pandas, polars or Arrow?](../33-turn-query-result-pandas-polars-arrow/page.md) (rank 33, works)
- How do I write a dataset partitioned by a column? (rank 97, gap; no page yet)
