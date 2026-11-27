-- A large mean with a small spread: var_samp, stddev_samp, var_pop and stddev_pop
-- of 1000000000 + v are those of v itself.
SELECT var_samp(v + 1000000000) AS vs, stddev_samp(v + 1000000000) AS sds, var_pop(v + 1000000000) AS vp, stddev_pop(v + 1000000000) AS sdp FROM agg_scalar ORDER BY vs ASC NULLS LAST
