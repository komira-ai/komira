from pathlib import Path

import komira

Path("contacts.csv").write_text(
    "id,contact\n"
    "1,ana@shop.example\n"
    "2,bo@mail.example\n"
    "3,no email\n"
    "4,cy@shop.example\n"
)

# SQL: regexp_extract(text, pattern, group) returns the text of one capture group.
with komira.Session() as s:
    s.register_csv("contacts", "contacts.csv")
    domains = s.sql(
        "SELECT id, regexp_extract(contact, '@([a-z.]+)', 1) AS domain"
        " FROM contacts ORDER BY id"
    )
    print(domains.to_arrow().to_pylist())

# pandas-shaped: Series.str.extract with one capture group and expand=False.
df = komira.read_csv("contacts.csv")
df = df.assign(domain=df["contact"].str.extract(r"@([a-z.]+)", expand=False))
print(df.sort_values("id").materialize().to_arrow().to_pylist())
