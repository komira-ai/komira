-- order: rows
-- sign(i) on a group key in having
SELECT i AS z FROM T GROUP BY i HAVING sign(i) < 0
