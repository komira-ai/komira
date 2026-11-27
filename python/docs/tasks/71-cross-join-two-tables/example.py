from pathlib import Path

import komira

Path("sizes.csv").write_text("size\nS\nM\nL\n")
Path("colors.csv").write_text("color,code\nred,1\nblue,2\n")

# SQL: CROSS JOIN pairs every row of one table with every row of the other.
with komira.Session() as s:
    s.register_csv("sizes", "sizes.csv")
    s.register_csv("colors", "colors.csv")
    pairs = s.sql(
        "SELECT size, color FROM sizes CROSS JOIN colors ORDER BY size, color"
    )
    print(pairs.to_arrow().to_pylist())

    # A comma between the tables, with no join condition, is the same join.
    n = s.sql("SELECT count(*) AS n FROM sizes, colors")
    print(n.to_arrow().to_pylist())

# pandas-shaped: merge with how="cross" takes no keys.
sizes = komira.read_csv("sizes.csv")
colors = komira.read_csv("colors.csv")
both = sizes.merge(colors, how="cross").sort_values(["size", "color"])
print(both.materialize().to_arrow().to_pylist())
