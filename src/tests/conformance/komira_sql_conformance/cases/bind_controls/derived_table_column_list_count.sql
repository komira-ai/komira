-- order: rows
-- A query shaped like a bind error that DuckDB answers.
SELECT z FROM (SELECT k, g FROM T) d (z)
