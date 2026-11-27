from pathlib import Path

import komira

# Two versions of a small stock table, keyed by id.
Path("stock_old.csv").write_text("id,qty\n1,10\n2,5\n3,7\n")
Path("stock_new.csv").write_text("id,qty\n2,5\n3,9\n4,3\n")

# SQL: a FULL JOIN on the key lines the versions up. A row with no partner
# was removed or added; a row with two different values changed.
with komira.Session() as s:
    s.register_csv("stock_old", "stock_old.csv")
    s.register_csv("stock_new", "stock_new.csv")
    diff = s.sql(
        "SELECT coalesce(o.id, n.id) AS key_id,"
        " CASE WHEN n.id IS NULL THEN 'removed'"
        " WHEN o.id IS NULL THEN 'added' ELSE 'changed' END AS kind,"
        " o.qty AS old_qty, n.qty AS new_qty"
        " FROM stock_old AS o FULL JOIN stock_new AS n ON o.id = n.id"
        " WHERE o.id IS NULL OR n.id IS NULL OR o.qty <> n.qty"
        " ORDER BY key_id"
    )
    for row in diff.to_arrow().to_pylist():
        print(row)

# pandas-shaped: the same three questions, one frame each.
old = komira.read_csv("stock_old.csv")
new = komira.read_csv("stock_new.csv")
removed = old[~old["id"].isin(new["id"])]
added = new[~new["id"].isin(old["id"])]
both = old.merge(new, on="id", suffixes=("_old", "_new"))
changed = both[both["qty_old"] != both["qty_new"]]
for frame in (removed, added, changed):
    print(frame.sort_values("id").materialize().to_arrow().to_pylist())
