-- No row at all: these aggregates are NULL.
SELECT median(i32) AS med, stddev_samp(v) AS sds, var_pop(v) AS vp, quantile_cont(i32, 0.25) AS q1 FROM nulls WHERE id < 0 ORDER BY med ASC NULLS LAST
