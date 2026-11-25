-- abs, floor, ceil, round and sqrt.
SELECT id, abs(i32) AS a, floor(v) AS fl, ceil(v) AS ce, round(v) AS ro, sqrt(abs(v)) AS sq FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
