-- order: rows
-- a union of two grouped aggregates
SELECT s, count(*) AS n, sum(i) AS total FROM A GROUP BY s UNION ALL SELECT s, count(*), sum(i) FROM B GROUP BY s
