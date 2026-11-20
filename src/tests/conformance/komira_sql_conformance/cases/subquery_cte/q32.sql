-- order: rows
-- a cte that shadows a base-table name
WITH T AS (SELECT j AS k FROM U) SELECT k FROM T
