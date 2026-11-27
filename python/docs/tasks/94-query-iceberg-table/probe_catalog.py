# The form komira does not read yet: a table of an Iceberg REST catalog,
# bound as a catalog and named catalog.namespace.table in SQL
# (komira-ai/komira#2481). It must fail with the line of
# probe_catalog.error.txt.
import komira

catalog = komira.iceberg(
    "https://catalog.example.com/api/catalog",
    warehouse="analytics",
    credential=komira.ANONYMOUS,
)
with komira.Session() as s:
    s.add_sql_binding("lake", catalog)
    print(s.sql("SELECT count(*) AS n FROM lake.rides.trips").to_arrow().to_pylist())
