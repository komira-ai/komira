-- median, stddev and variance over a DOUBLE column holding NULLs, no group.
SELECT median(v) AS med, stddev_samp(v) AS sds, stddev_pop(v) AS sdp, var_samp(v) AS vs, var_pop(v) AS vp FROM nulls WHERE id < 200 ORDER BY med ASC NULLS LAST
