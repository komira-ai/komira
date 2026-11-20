-- order: rows
-- The query as first written; it has an answer.
SELECT k AS z FROM T WHERE k IN (SELECT j + 1 FROM U)
