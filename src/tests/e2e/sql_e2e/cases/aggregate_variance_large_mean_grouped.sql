-- var_samp and stddev_samp of 1000000000 + val per group of count_groups, and of
-- 1000000000 + i32 per group of k.
SELECT id, var_samp(val + 1000000000) AS vs, stddev_samp(val + 1000000000) AS sds, var_pop(val + 1000000000) AS vp FROM count_groups GROUP BY id ORDER BY id ASC NULLS LAST
