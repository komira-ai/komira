-- Double-quoted identifiers: an alias keeps its case and reads "" as one quote, a column resolves whatever the case of its quoted name, and a quoted keyword is a plain column name.
SELECT "order", "MIXED CASE" AS "Say ""Hi""", "T"."select" AS "From" FROM (SELECT "ID" AS "order", i32 AS "Mixed Case", v AS "select" FROM "NULLS" WHERE "Id" < 20) AS "T" ORDER BY "order" ASC NULLS LAST
