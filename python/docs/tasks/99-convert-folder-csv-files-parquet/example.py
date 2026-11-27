from pathlib import Path

import komira

# A folder of CSV files with the same columns.
folder = Path("sales").resolve()
folder.mkdir()
(folder / "jan.csv").write_text("order_id,item,qty\n1,apple,3\n2,pear,5\n")
(folder / "feb.csv").write_text("order_id,item,qty\n3,apple,2\n4,fig,7\n5,pear,1\n")
(folder / "mar.csv").write_text("order_id,item,qty\n6,fig,4\n")

# One Parquet file per CSV file: COPY writes the rows read_csv reads.
out = Path("parquet").resolve()
out.mkdir()
with komira.Session() as s:
    for src in sorted(folder.glob("*.csv")):
        dest = out / (src.stem + ".parquet")
        copied = s.sql(
            f"COPY (SELECT * FROM read_csv('{src}')) TO '{dest}' (FORMAT parquet)"
        ).to_arrow().to_pylist()
        print(src.name, "->", dest.name, copied[0]["Count"], "rows")

    # Read one of the new files back.
    s.register_parquet("feb", str(out / "feb.parquet"))
    for row in s.sql("SELECT * FROM feb ORDER BY order_id").to_arrow().to_pylist():
        print(row)
