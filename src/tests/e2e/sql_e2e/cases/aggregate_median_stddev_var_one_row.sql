-- One non-NULL value: the sample forms are NULL, the population forms 0.0.
SELECT median(i32) AS med, stddev_samp(i32) AS sds, stddev_pop(i32) AS sdp, var_samp(i32) AS vs, var_pop(i32) AS vp FROM nulls WHERE id = 3 ORDER BY med ASC NULLS LAST
