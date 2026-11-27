-- median and the sample and population standard deviation and variance of an
-- INTEGER column holding NULLs, no group.
SELECT median(i32) AS med, stddev(i32) AS sd, stddev_samp(i32) AS sds, stddev_pop(i32) AS sdp, variance(i32) AS vr, var_samp(i32) AS vs, var_pop(i32) AS vp FROM nulls ORDER BY med ASC NULLS LAST
