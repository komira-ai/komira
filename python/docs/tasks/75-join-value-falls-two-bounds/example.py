from pathlib import Path

import komira

Path("readings.csv").write_text("id,reading\n1,5\n2,10\n3,19\n4,25\n5,40\n")
Path("bands.csv").write_text("band,lo,hi\nlow,0,9\nmid,10,19\nhigh,20,29\n")

with komira.Session() as s:
    s.register_csv("readings", "readings.csv")
    s.register_csv("bands", "bands.csv")

    # A range join: ON takes a condition between the two tables, not only
    # an equality. BETWEEN includes both bounds.
    banded = s.sql(
        "SELECT r.id AS id, r.reading AS reading, b.band AS band"
        " FROM readings AS r JOIN bands AS b"
        " ON r.reading BETWEEN b.lo AND b.hi ORDER BY r.id"
    )
    print(banded.to_arrow().to_pylist())

    # The same join with two comparisons: here the upper bound is excluded.
    half_open = s.sql(
        "SELECT r.id AS id, b.band AS band"
        " FROM readings AS r JOIN bands AS b"
        " ON r.reading >= b.lo AND r.reading < b.hi ORDER BY r.id"
    )
    print(half_open.to_arrow().to_pylist())
