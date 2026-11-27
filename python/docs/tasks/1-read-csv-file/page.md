# How do I read a CSV file?

Register the file with `Session.register_csv` and query it with SQL, or read it as a pandas-shaped frame with `komira.read_csv`.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# A small CSV file to read: an empty field reads as NULL.
Path("people.csv").write_text(
    "id,name,city,score\n"
    "1,Ana,Oslo,9.5\n"
    "2,Bo,Lima,7.0\n"
    "3,Cy,Oslo,\n"
)

# SQL: register the file as a table and query it.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    for row in s.sql("SELECT * FROM people ORDER BY id").to_arrow().to_pylist():
        print(row)

# pandas-shaped: komira.read_csv infers the column names and types now
# and reads the rows when the frame runs.
df = komira.read_csv("people.csv")
print(df.columns)
print(df.dtypes["id"], df.dtypes["score"])
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# Another delimiter: one ASCII character between fields.
Path("people.tsv").write_text("id\tname\n1\tAna\n2\tBo\n")
tsv = komira.read_csv("people.tsv", sep="\t")
print(tsv.sort_values("id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'id': 1, 'name': 'Ana', 'city': 'Oslo', 'score': 9.5}
{'id': 2, 'name': 'Bo', 'city': 'Lima', 'score': 7.0}
{'id': 3, 'name': 'Cy', 'city': 'Oslo', 'score': None}
['id', 'name', 'city', 'score']
int64 float64
[{'id': 1, 'name': 'Ana', 'city': 'Oslo', 'score': 9.5}, {'id': 2, 'name': 'Bo', 'city': 'Lima', 'score': 7.0}, {'id': 3, 'name': 'Cy', 'city': 'Oslo', 'score': None}]
[{'id': 1, 'name': 'Ana'}, {'id': 2, 'name': 'Bo'}]
```

## Notes

- The engine infers the column names and types from the start of the file when you register or read it; the rows are read when a query runs.
- An empty field reads as NULL (`None` in Python).
- `sep` (pandas-shaped) and `delimiter` (`register_csv`) take one ASCII character.
- A file without a header line is refused today: `header=None` and `header=False` raise an error naming `header=false`.
- Gzip, zstd and lz4 compressed CSV files read the same way.

## Related

- How do I read a Parquet file? (rank 15, works; no page yet)
- How do I read many files matching a pattern into one table? (rank 19, partial; no page yet)
- How do I read a CSV with an odd delimiter, no header or extra lines? (rank 100, partial; no page yet)
- [How do I look at the first rows, row count and columns of a dataset?](../5-look-at-first-rows-and-columns/page.md) (rank 5, works)
