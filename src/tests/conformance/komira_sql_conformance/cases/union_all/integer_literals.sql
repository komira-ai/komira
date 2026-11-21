-- order: rows
-- integer literals: INTEGER, widened to BIGINT by a large one
SELECT typeof(v) AS t, v FROM (SELECT 1 AS v UNION ALL SELECT 5000000000 UNION ALL SELECT 2) u
