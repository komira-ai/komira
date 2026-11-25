-- Two boolean columns compared with = and <> are NULL when either is NULL, as DuckDB's comparison is.
SELECT id, b1 = b2 AS eq, b1 <> b2 AS ne FROM nulls WHERE id < 200 ORDER BY id ASC NULLS LAST
