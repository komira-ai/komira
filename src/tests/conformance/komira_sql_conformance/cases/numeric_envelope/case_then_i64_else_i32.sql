-- order: rows
SELECT k, CASE WHEN k > 2 THEN a_i64 ELSE b_i32 END AS y FROM t
