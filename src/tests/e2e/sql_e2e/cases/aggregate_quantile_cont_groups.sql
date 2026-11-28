-- quantile_cont over the groups of count_groups: interpolation between two
-- values, a single value, and groups of only NULLs (NULL).
SELECT id, quantile_cont(val, 0.25) AS q1, quantile_cont(val, 0.75) AS q3 FROM count_groups GROUP BY id ORDER BY id ASC NULLS LAST
