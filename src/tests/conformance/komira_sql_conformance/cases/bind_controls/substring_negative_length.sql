-- order: rows
-- A query shaped like a bind error that DuckDB answers.
SELECT substring(s, 1, -1) AS z FROM T
