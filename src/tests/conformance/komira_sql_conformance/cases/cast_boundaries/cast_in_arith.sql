-- order: rows
SELECT k, CAST(i32 AS BIGINT) + 1 FROM T WHERE k > 1
