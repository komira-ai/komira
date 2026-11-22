-- order: rows
-- count, min and max over a derived union
SELECT count(*) AS n, min(v) AS lo, max(v) AS hi, typeof(max(v)) AS t FROM (SELECT i AS v FROM A UNION ALL SELECT bi FROM B) u
