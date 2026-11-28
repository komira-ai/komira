# How do I concatenate string columns?

In SQL, `concat(a, ' ', b)` joins columns and `concat_ws(' ', a, b, c)` joins them with a separator and skips a missing one; the `||` operator and `+` on the pandas-shaped frame are not supported yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("people.csv").write_text(
    "id,first,middle,last\n"
    "1,Ana,Q,Diaz\n"
    "2,Bo,,Lee\n"
    "3,Cy,R,Ito\n"
)

with komira.Session() as s:
    s.register_csv("people", "people.csv")

    # concat joins the values as they are.
    full = s.sql("SELECT id, concat(first, ' ', last) AS name FROM people ORDER BY id")
    print(full.to_arrow().to_pylist())

    # concat_ws puts a separator between the values and skips a missing one.
    spaced = s.sql(
        "SELECT id, concat_ws(' ', first, middle, last) AS name FROM people ORDER BY id"
    )
    print(spaced.to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'Ana Diaz'}, {'id': 2, 'name': 'Bo Lee'}, {'id': 3, 'name': 'Cy Ito'}]
[{'id': 1, 'name': 'Ana Q Diaz'}, {'id': 2, 'name': 'Bo Lee'}, {'id': 3, 'name': 'Cy R Ito'}]
```

## Notes

- `concat` and `concat_ws` both skip a NULL value, as in DuckDB: `concat('Cy', NULL)` is `'Cy'`. `concat_ws` also leaves out the separator for it, which is why the second row above has no double space.
- The `||` operator is refused by name. In DuckDB `'a' || NULL` is NULL, which differs from `concat`, and the engine cannot yet return a NULL string for it, so it does not answer with the `concat` result instead. Use `concat` where no value can be NULL.
- Adding string columns with `+` on the pandas-shaped frame (`df["first"] + " " + df["last"]`) fails today, so the example does not use it; do the join in SQL. `Series.str.cat` is refused by name.
- `concat` takes string columns only: `concat(1, first)` is refused, so cast a number to text first.
- Because `||` and `+` are missing, this task is partial: komira-ai/komira#2373. `probe_pipe_operator.py` and `probe_pandas_plus.py` beside this page try them and must fail with the lines in their `.error.txt` files. The day they run, this page's check goes red, and the page and the catalogue status change with it.

## Related

- [How do I filter rows where a text column contains a substring?](../41-filter-rows-text-column-contains-substring/page.md) (rank 41, works)
- [How do I lowercase, trim and replace text in a column?](../42-lowercase-trim-replace-text-column/page.md) (rank 42, works)
- [How do I split a string column into several columns?](../44-split-string-column-columns/page.md) (rank 44, partial)
