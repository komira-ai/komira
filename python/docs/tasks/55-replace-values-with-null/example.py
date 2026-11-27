from pathlib import Path

import komira
from komira import pl

Path("contacts.csv").write_text(
    "name,city,phone,score\n"
    "Ana,Oslo,555-0101,8\n"
    "Bo,N/A,n/a,-1\n"
    "Cy,Lima,555-0103,6\n"
    "Di,N/A,-,-1\n"
)

# polars-shaped: when(value is a placeholder) then None, otherwise keep it.
# is_in takes a list of spellings, so several placeholders are one condition.
placeholders = ["N/A", "n/a", "-"]
clean = (
    pl.scan_csv("contacts.csv")
    .with_columns(
        *[
            pl.when(pl.col(c).is_in(placeholders)).then(None).otherwise(pl.col(c)).alias(c)
            for c in ["city", "phone"]
        ]
    )
    .sort("name")
    .collect()
)
print(clean.to_arrow().to_pylist())

# SQL: NULLIF(value, sentinel) is NULL where the value equals the sentinel.
# It takes a numeric column; a text column goes through the frame above.
with komira.Session() as s:
    s.register_csv("contacts", "contacts.csv")
    scores = s.sql("SELECT name, NULLIF(score, -1) AS score FROM contacts ORDER BY name")
    print(scores.to_arrow().to_pylist())
    mean = s.sql("SELECT avg(NULLIF(score, -1)) AS mean FROM contacts").to_arrow().to_pylist()
    print(mean)
