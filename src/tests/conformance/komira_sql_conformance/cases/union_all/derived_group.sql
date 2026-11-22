-- order: rows
-- a group over a derived union of three branches
SELECT k, count(*) AS n, max(v) AS hi FROM (SELECT 'a' AS k, i AS v FROM A UNION ALL SELECT 'b', i FROM B UNION ALL SELECT 'a', i FROM B) u GROUP BY k
