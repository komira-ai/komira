-- order: rows
-- The query as first written; it has an answer.
WITH c AS (SELECT k FROM T) SELECT z FROM (SELECT k AS z FROM T) c
