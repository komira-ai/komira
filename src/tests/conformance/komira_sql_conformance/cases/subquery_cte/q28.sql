-- order: rows
-- a cte that references an earlier cte
WITH c AS (SELECT k FROM T), d AS (SELECT k FROM c) SELECT k FROM d
