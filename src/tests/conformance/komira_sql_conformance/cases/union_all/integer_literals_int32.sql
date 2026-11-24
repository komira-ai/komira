-- order: rows
-- integer literals that fit stay INTEGER
SELECT typeof(v) AS t, v FROM (SELECT 1 AS v UNION ALL SELECT 2) u
