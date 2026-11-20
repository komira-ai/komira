-- order: rows
-- A query shaped like a bind error that DuckDB answers.
WITH c AS (SELECT k FROM T) SELECT z FROM (SELECT k AS z FROM T) c
