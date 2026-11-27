from pathlib import Path

import komira

Path("sales.csv").write_text(
    "rep,region,amount\n"
    "ana,north,100\n"
    "bo,north,100\n"
    "cy,north,70\n"
    "di,south,90\n"
    "ed,south,40\n"
)

# SQL: window functions over a partition. RANK leaves a gap after a tie,
# DENSE_RANK does not, ROW_NUMBER numbers the rows without ties.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    over = "OVER (PARTITION BY region ORDER BY amount DESC"
    sql = (
        "SELECT region, rep, amount,"
        f" RANK() {over}) AS rnk,"
        f" DENSE_RANK() {over}) AS dense,"
        f" ROW_NUMBER() {over}, rep) AS rn"
        " FROM sales ORDER BY region, rn"
    )
    for row in s.sql(sql).to_arrow().to_pylist():
        print(row)

# pandas-shaped: groupby(...).rank, with the tie method named.
df = komira.read_csv("sales.csv")
df["rnk"] = df.groupby("region")["amount"].rank(method="min", ascending=False)
df["dense"] = df.groupby("region")["amount"].rank(method="dense", ascending=False)
out = df.sort_values(["region", "rep"]).materialize().to_arrow()
for row in out.to_pylist():
    print(row)
