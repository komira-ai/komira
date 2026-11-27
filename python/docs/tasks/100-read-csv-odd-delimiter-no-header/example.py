from pathlib import Path

import komira

# A pipe-separated file and a semicolon-separated one, each with a header line.
Path("orders.psv").write_text("id|name|qty\n1|Ana|3\n2|Bo|5\n")
Path("orders_eu.csv").write_text("id;name;qty\n3;Cy;7\n4;Di;2\n")

# SQL: name the delimiter when you register the file.
with komira.Session() as s:
    s.register_csv("orders", "orders.psv", delimiter="|")
    print(s.sql("SELECT * FROM orders ORDER BY id").to_arrow().to_pylist())

# pandas-shaped: sep= is the delimiter, as in pandas.
eu = komira.read_csv("orders_eu.csv", sep=";")
print(eu.sort_values("id").materialize().to_arrow().to_pylist())

# No header line: every line is a row, and the columns are named column0,
# column1, ... as DuckDB names them.
Path("scores.csv").write_text('1,Ana,3\n2,"Bo, Jr.",5\n')

with komira.Session() as s:
    s.register_csv("scores", "scores.csv", header=False)
    print(s.sql("SELECT * FROM scores ORDER BY column0").to_arrow().to_pylist())

bare = komira.read_csv("scores.csv", header=None)
print(bare.sort_values("column0").materialize().to_arrow().to_pylist())
