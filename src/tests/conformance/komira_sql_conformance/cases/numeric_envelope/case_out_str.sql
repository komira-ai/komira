-- order: rows
SELECT k, CASE WHEN k > 2 THEN s1 ELSE s2 END AS y FROM t
