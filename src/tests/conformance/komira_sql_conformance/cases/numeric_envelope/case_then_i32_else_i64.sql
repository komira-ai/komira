-- order: rows
SELECT k, CASE WHEN k > 2 THEN a_i32 ELSE b_i64 END AS y FROM t
