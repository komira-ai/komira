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
print(df.dtypes)
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# Another delimiter: one ASCII character between fields.
Path("people.tsv").write_text("id\tname\n1\tAna\n2\tBo\n")
tsv = komira.read_csv("people.tsv", sep="\t")
print(tsv.sort_values("id").materialize().to_arrow().to_pylist())
