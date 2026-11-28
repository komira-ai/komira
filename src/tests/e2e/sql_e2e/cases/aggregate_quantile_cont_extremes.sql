-- median and quantile_cont between two values at the ends of the double range:
-- DuckDB interpolates lo * (1 - d) + hi * d, so -DBL_MAX and DBL_MAX give 0.0
-- at the median and -DBL_MAX / 2 at a quarter (not an infinity), and two
-- smallest subnormals give 0.0 (each half rounds to zero).
SELECT median(CASE WHEN v < 2 THEN (2 * v - 1) * 1.7976931348623157e308 END) AS m_wide, quantile_cont(CASE WHEN v < 2 THEN (2 * v - 1) * 1.7976931348623157e308 END, 0.25) AS q_wide, median(CASE WHEN v < 2 THEN 5e-324 END) AS m_tiny FROM agg_scalar ORDER BY m_wide ASC NULLS LAST
