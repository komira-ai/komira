-- order: rows
-- a derived table whose body reads a cte
WITH c AS (SELECT k FROM T) SELECT k FROM (SELECT k FROM c) t
