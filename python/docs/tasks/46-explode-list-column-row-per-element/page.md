# How do I explode a list column into one row per element?

Select `unnest(list)` in SQL, or call `.explode(column)` on the pandas-shaped frame (`LazyFrame.explode(column)` on the polars-shaped one); the other columns repeat on every element's row.

<!-- include example.py -->
```python
from pathlib import Path

import pyarrow.parquet as pq

import komira

Path("posts.csv").write_text("id,tags\n1,red;blue\n2,green\n3,blue;green;yellow\n")

with komira.Session() as s:
    s.register_csv("posts", "posts.csv")
    # SQL: unnest(list) as a SELECT item gives one row per element, the other
    # items repeated. string_split makes the list.
    sql = (
        "SELECT id, unnest(string_split(tags, ';')) AS tag"
        " FROM posts ORDER BY id, tag"
    )
    for row in s.sql(sql).to_arrow().to_pylist():
        print(row)
    # The same lists as a column, kept in a Parquet file for the frame below.
    lists = s.sql("SELECT id, string_split(tags, ';') AS tags FROM posts")
    pq.write_table(lists.to_arrow(), "posts.parquet")

# pandas-shaped: explode replaces the list column by its elements.
df = komira.read_parquet("posts.parquet").explode("tags")
print(df.sort_values(["id", "tags"]).materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'id': 1, 'tag': 'blue'}
{'id': 1, 'tag': 'red'}
{'id': 2, 'tag': 'green'}
{'id': 3, 'tag': 'blue'}
{'id': 3, 'tag': 'green'}
{'id': 3, 'tag': 'yellow'}
[{'id': 1, 'tags': 'blue'}, {'id': 1, 'tags': 'red'}, {'id': 2, 'tags': 'green'}, {'id': 3, 'tags': 'blue'}, {'id': 3, 'tags': 'green'}, {'id': 3, 'tags': 'yellow'}]
```

## Notes

- An empty or NULL list is where the two forms differ, and each follows its own model. SQL `unnest` follows DuckDB: such a row gives no row. `explode` follows pandas and polars: such a row gives one row whose element is NULL (pandas shows it as NaN). Both lower to the same plan node, which carries that choice as a flag.
- `unnest` is served as a whole SELECT item, with or without `AS name`; unaliased, the column is named `unnest(<argument>)` as in DuckDB. Two `unnest` items in one SELECT, `unnest` inside an expression or outside the SELECT list, and `unnest` beside an aggregate, `GROUP BY`, a window function or `*` are refused with a message saying so.
- `explode` takes one column, by name. A list of columns is refused (explode them one after another), and so is a column that is not a list. The exploded column has the list's element type, where pandas gives an `object` column. `ignore_index` is accepted and changes nothing, since a komira frame has no index.
- The list column here comes from SQL `string_split`, written to Parquet with pyarrow. List columns cannot be read from JSON yet (rank 45, komira-ai/komira#2338).

## Related

- [How do I split a string column into several columns?](../44-split-string-column-columns/page.md) (rank 44, partial)
- How do I flatten nested JSON into columns? (rank 45, gap; no page yet)
- [How do I melt (unpivot) wide data to long?](../52-melt-wide-data-long/page.md) (rank 52, partial)
