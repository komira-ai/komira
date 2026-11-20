-- order: rows
-- a single `with` cte
WITH c AS (SELECT k FROM T) SELECT k FROM c
