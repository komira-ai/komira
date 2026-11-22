-- order: rows
-- A query shaped like a bind error that DuckDB answers.
SELECT k AS z FROM T WHERE k IN (SELECT j + 1 FROM U)
