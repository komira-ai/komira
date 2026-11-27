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

# A file with a note line above its header.
Path("notes.csv").write_text("exported by the till\nid,name,qty\n5,Ed,1\n6,Flo,4\n")

# SQL: skip = n drops the first n lines before the header.
with komira.Session() as s:
    print(s.sql("SELECT * FROM read_csv('notes.csv', skip = 1) ORDER BY id").to_arrow().to_pylist())

# SQL, registered: skip= on register_csv does the same.
with komira.Session() as s:
    s.register_csv("notes", "notes.csv", skip=1)
    print(s.sql("SELECT * FROM notes ORDER BY id").to_arrow().to_pylist())

# pandas-shaped: skiprows= is the number of lines to skip, as in pandas.
notes = komira.read_csv("notes.csv", skiprows=1)
print(notes.sort_values("id").materialize().to_arrow().to_pylist())
