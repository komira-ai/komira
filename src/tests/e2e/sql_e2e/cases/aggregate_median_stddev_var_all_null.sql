-- Every one of these aggregates over no non-NULL value (a column that is NULL
-- in every row) is NULL, never 0 or NaN.
SELECT median(all_null) AS med, stddev_samp(all_null) AS sds, stddev_pop(all_null) AS sdp, var_samp(all_null) AS vs, var_pop(all_null) AS vp FROM nulls ORDER BY med ASC NULLS LAST
