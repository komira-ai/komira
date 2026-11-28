-- median, stddev and variance over a DOUBLE column of quarters holding NULLs,
-- per group of k over the first 200 rows.
SELECT k, median(v) AS med, stddev_samp(v) AS sds, stddev_pop(v) AS sdp, var_samp(v) AS vs, var_pop(v) AS vp FROM nulls WHERE id < 200 GROUP BY k ORDER BY k ASC NULLS FIRST
