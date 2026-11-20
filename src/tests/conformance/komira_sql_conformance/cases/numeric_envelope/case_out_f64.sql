-- order: rows
SELECT k, CASE WHEN k > 2 THEN a_f64 ELSE b_f64 END AS y FROM t
