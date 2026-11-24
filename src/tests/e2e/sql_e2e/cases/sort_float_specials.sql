-- DOUBLE with NaN (greatest), both infinities and NULLs last, ties broken by
-- id. The zero rows are left out: this DuckDB writes a DOUBLE it sorted on
-- from its sort key, which holds no -0.0, so it answers 0.0 for a stored
-- -0.0 where komira answers the stored -0.0.
SELECT id, f64_special FROM types WHERE f64_special IS NULL OR f64_special <> 0 ORDER BY f64_special ASC NULLS LAST, id ASC NULLS LAST
