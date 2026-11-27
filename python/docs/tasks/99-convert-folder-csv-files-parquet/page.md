# How do I convert a folder of CSV files to Parquet?

Loop over the folder and run `COPY (SELECT * FROM read_csv('<file>')) TO '<file>.parquet' (FORMAT parquet)` for each CSV file; each COPY writes one Parquet file and reports how many rows it wrote.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# A folder of CSV files with the same columns.
folder = Path("sales").resolve()
folder.mkdir()
(folder / "jan.csv").write_text("order_id,item,qty\n1,apple,3\n2,pear,5\n")
(folder / "feb.csv").write_text("order_id,item,qty\n3,apple,2\n4,fig,7\n5,pear,1\n")
(folder / "mar.csv").write_text("order_id,item,qty\n6,fig,4\n")

# One Parquet file per CSV file: COPY writes the rows read_csv reads.
out = Path("parquet").resolve()
out.mkdir()
with komira.Session() as s:
    for src in sorted(folder.glob("*.csv")):
        dest = out / (src.stem + ".parquet")
        copied = s.sql(
            f"COPY (SELECT * FROM read_csv('{src}')) TO '{dest}' (FORMAT parquet)"
        ).to_arrow().to_pylist()
        print(src.name, "->", dest.name, copied[0]["Count"], "rows")

    # Read one of the new files back.
    s.register_parquet("feb", str(out / "feb.parquet"))
    for row in s.sql("SELECT * FROM feb ORDER BY order_id").to_arrow().to_pylist():
        print(row)
```

Output:

<!-- include expected_output.txt -->
```text
feb.csv -> feb.parquet 3 rows
jan.csv -> jan.parquet 2 rows
mar.csv -> mar.parquet 1 rows
{'order_id': 3, 'item': 'apple', 'qty': 2}
{'order_id': 4, 'item': 'fig', 'qty': 7}
{'order_id': 5, 'item': 'pear', 'qty': 1}
```

## Notes

- The column names and types come from the CSV file (`read_csv` infers them from the start of the file), and the Parquet file keeps them.
- Each CSV file becomes its own Parquet file. `read_csv` takes one file path, so the loop names each file: to put the files into one Parquet file, see rank 19 below.
- `COPY ... TO` takes `COMPRESSION` (for example `zstd` or `snappy`) beside `FORMAT parquet`.
- Use `sorted(folder.glob("*.csv"))` so the files are converted in a fixed order; the rows of a query come back in no promised order unless it sorts them.

## Related

- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- [How do I concatenate (stack) tables with the same columns?](../18-concatenate-tables-same-columns/page.md) (rank 18, works)
- [How do I read many files matching a pattern into one table?](../19-read-many-files-matching-pattern-table/page.md) (rank 19, partial)
- [How do I write a table to Parquet?](../27-write-table-parquet/page.md) (rank 27, partial)
