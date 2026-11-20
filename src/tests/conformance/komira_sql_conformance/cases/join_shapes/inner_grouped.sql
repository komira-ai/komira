-- order: rows
SELECT lk, SUM(rv) AS s FROM L JOIN R ON lk = rk GROUP BY lk
