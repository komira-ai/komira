-- Groups of count_groups: three values, one value (sample forms NULL, population
-- forms 0.0), a NULL and one value, and groups holding only NULLs (NULL).
SELECT id, median(val) AS med, stddev_samp(val) AS sds, stddev_pop(val) AS sdp, var_samp(val) AS vs, var_pop(val) AS vp FROM count_groups GROUP BY id ORDER BY id ASC NULLS LAST
