from pathlib import Path

import komira

Path("scores.csv").write_text(
    "name,quarter,score\n"
    "Ana,q1,10\n"
    "Ana,q2,20\n"
    "Ana,q3,30\n"
    "Bo,q1,5\n"
    "Bo,q3,7\n"
    "Cy,q1,1\n"
    "Cy,q2,2\n"
)

# SQL PIVOT: one column per listed quarter, one row per name. A name with
# no row for a quarter gets NULL.
with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    wide = s.sql(
        "SELECT * FROM scores PIVOT (max(score) FOR quarter IN ('q1', 'q2', 'q3'))"
        " ORDER BY name"
    )
    print(wide.to_arrow().to_pylist())

    # The same table by hand: one aggregate over CASE WHEN per new column,
    # grouped by the row key.
    wide = s.sql(
        "SELECT name,"
        " max(CASE WHEN quarter = 'q1' THEN score END) AS q1,"
        " max(CASE WHEN quarter = 'q2' THEN score END) AS q2,"
        " max(CASE WHEN quarter = 'q3' THEN score END) AS q3"
        " FROM scores GROUP BY name ORDER BY name"
    )
    print(wide.to_arrow().to_pylist())

# pandas-shaped: one filtered frame per new column, merged on the row key.
df = komira.read_csv("scores.csv")
wide = df[["name"]].drop_duplicates()
for quarter in ["q1", "q2", "q3"]:
    part = df[df["quarter"] == quarter][["name", "score"]].rename(columns={"score": quarter})
    wide = wide.merge(part, on="name", how="left")
print(wide.sort_values("name").materialize().to_arrow().to_pylist())
