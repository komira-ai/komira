-- order: rows
SELECT k, CAST(i64 AS DECIMAL(18,4)) FROM T WHERE k > 1
