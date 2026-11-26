-- Window AVG, MIN and MAX of an INTEGER column per partition, over a frame
-- that can hold only NULLs.
SELECT id, k, i32, avg(i32) OVER (PARTITION BY k) AS a, min(i32) OVER (PARTITION BY k ORDER BY id ASC NULLS LAST ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS mn, max(i32) OVER (PARTITION BY k ORDER BY id ASC NULLS LAST) AS mx FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
