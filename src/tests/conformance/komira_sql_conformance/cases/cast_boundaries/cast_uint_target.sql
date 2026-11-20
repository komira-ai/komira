-- order: rows
SELECT k, CAST(i32 AS UBIGINT) FROM T WHERE k > 1 AND k < 4
