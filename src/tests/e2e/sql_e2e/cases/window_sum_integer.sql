-- A partition sum of an INTEGER column.
SELECT id, k, sum(i32) OVER (PARTITION BY k) AS total FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
