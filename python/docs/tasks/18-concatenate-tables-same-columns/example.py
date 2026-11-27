from pathlib import Path

import komira
from komira import pl

# Two months of orders, one file each, with the same columns.
Path("jan.csv").write_text("id,name,amt\n1,Ana,9.5\n2,Bo,7.0\n")
Path("feb.csv").write_text("id,name,amt\n3,Cy,4.25\n4,Di,\n")

# SQL: UNION ALL stacks the rows and keeps duplicates; UNION drops them.
with komira.Session() as s:
    s.register_csv("jan", "jan.csv")
    s.register_csv("feb", "feb.csv")
    stacked = s.sql("SELECT * FROM jan UNION ALL SELECT * FROM feb ORDER BY id")
    print(stacked.to_arrow().to_pylist())
    # Tag each row with the table it came from.
    tagged = s.sql(
        "SELECT 'jan' AS month, id, name, amt FROM jan"
        " UNION ALL SELECT 'feb', id, name, amt FROM feb ORDER BY id"
    )
    print(tagged.to_arrow().to_pylist())

# pandas-shaped: komira.concat takes a list of frames.
jan = komira.read_csv("jan.csv")
feb = komira.read_csv("feb.csv")
both = komira.concat([jan, feb])
print(both.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: pl.concat stacks LazyFrames.
lazy = pl.concat([pl.scan_csv("jan.csv"), pl.scan_csv("feb.csv")])
print(lazy.sort("id").collect().to_arrow().to_pylist())
