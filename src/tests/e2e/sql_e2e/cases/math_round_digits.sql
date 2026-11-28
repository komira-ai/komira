-- round and trunc with a digit count, over DOUBLE and INTEGER columns with NULLs.
SELECT id, round(v, 2) AS r2, trunc(v, 1) AS t1, round(i32, -1) AS ri FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
