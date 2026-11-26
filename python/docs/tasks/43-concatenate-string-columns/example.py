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
