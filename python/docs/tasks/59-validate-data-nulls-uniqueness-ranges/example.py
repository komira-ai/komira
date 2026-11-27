from pathlib import Path

import komira

Path("people.csv").write_text(
    "id,name,age\n1,Ana,34\n2,Bo,\n3,Cy,29\n3,Di,150\n5,,41\n6,Ed,-2\n"
)

# One query per rule; each returns the number of rows that break it.
checks = {
    "name is null": "SELECT count(*) AS bad FROM people WHERE name IS NULL",
    "age is null": "SELECT count(*) AS bad FROM people WHERE age IS NULL",
    "age outside 0..120": "SELECT count(*) AS bad FROM people WHERE age < 0 OR age > 120",
    "id repeated": (
        "SELECT count(*) AS bad FROM (SELECT id FROM people GROUP BY id HAVING count(*) > 1) AS d"
    ),
}

with komira.Session() as s:
    s.register_csv("people", "people.csv")
    for rule, sql in checks.items():
        bad = s.sql(sql).to_arrow().to_pylist()[0]["bad"]
        print(f"{'FAIL' if bad else 'ok  '} {rule}: {bad}")
    # The offending rows, not just their count.
    for row in s.sql(
        "SELECT id, name, age FROM people"
        " WHERE name IS NULL OR age IS NULL OR age < 0 OR age > 120 ORDER BY id, name"
    ).to_arrow().to_pylist():
        print(row)
