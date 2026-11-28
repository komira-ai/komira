-- The same aggregates per group of k, one row per group, the NULL group first.
SELECT k, median(i32) AS med, stddev_samp(i32) AS sds, stddev_pop(i32) AS sdp, var_samp(i32) AS vs, var_pop(i32) AS vp FROM nulls GROUP BY k ORDER BY k ASC NULLS FIRST
