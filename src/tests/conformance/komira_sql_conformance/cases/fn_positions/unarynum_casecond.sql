-- order: rows
-- sign(i) in a case condition
SELECT k, CASE WHEN sign(i) < 0 THEN 'y' ELSE 'n' END AS z FROM T
