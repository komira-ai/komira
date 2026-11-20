-- order: rows
-- `with recursive` the real recursive spelling a customer writes
WITH RECURSIVE c(n) AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM c WHERE n < 3) SELECT n FROM c
