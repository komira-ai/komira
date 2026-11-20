-- order: rows
SELECT sum(CAST(i32 AS BIGINT)) FROM T WHERE k > 1
