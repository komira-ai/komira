# The form komira does not have yet: SQL that names a DataFrame, as
# SELECT * FROM df does for the variable df. It must fail with the line of
# probe_dataframe_in_sql.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("id,amount\n1,120\n2,80\n")
df = komira.read_csv("sales.csv")

with komira.Session() as s:
    s.sql("SELECT * FROM df")
