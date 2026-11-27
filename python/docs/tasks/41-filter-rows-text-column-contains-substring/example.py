from pathlib import Path

import komira

Path("products.csv").write_text(
    "id,name\n"
    "1,Red Widget\n"
    "2,blue widget\n"
    "3,Gadget (large)\n"
    "4,Widget Pro\n"
    "5,Gizmo\n"
)

# SQL: LIKE matches a pattern (% is any text); contains() matches the text itself.
with komira.Session() as s:
    s.register_csv("products", "products.csv")
    like = s.sql("SELECT id FROM products WHERE name LIKE '%Widget%' ORDER BY id")
    print(like.to_arrow().to_pylist())

    literal = s.sql("SELECT id FROM products WHERE contains(name, '(large)') ORDER BY id")
    print(literal.to_arrow().to_pylist())

    # Case-insensitive: ILIKE, or lower() on both sides.
    ci = s.sql("SELECT id FROM products WHERE name ILIKE '%widget%' ORDER BY id")
    print(ci.to_arrow().to_pylist())

    starts = s.sql("SELECT id FROM products WHERE starts_with(name, 'Widget') ORDER BY id")
    print(starts.to_arrow().to_pylist())

# pandas-shaped: regex=False searches for the text, not a regular expression.
df = komira.read_csv("products.csv")
hit = df[df["name"].str.contains("(large)", regex=False)]
print(hit.materialize().to_arrow().to_pylist())

ci = df[df["name"].str.contains("widget", case=False)]
print(ci.sort_values("id").materialize().to_arrow().to_pylist())

starts = df[df["name"].str.startswith("Widget")]
print(starts.materialize().to_arrow().to_pylist())
