-- order: rows
SELECT k, CASE WHEN k > 2 THEN a_f32 ELSE b_f32 END AS y FROM t
