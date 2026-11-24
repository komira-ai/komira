-- QUALIFY filters on a window function.
SELECT id, k FROM nulls WHERE id < 50 QUALIFY row_number() OVER (PARTITION BY k ORDER BY id ASC NULLS LAST) = 1 ORDER BY id ASC NULLS LAST
