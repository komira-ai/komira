-- order: rows
-- a cte carrying its own where
WITH c AS (SELECT k FROM T WHERE k > 2) SELECT k FROM c
