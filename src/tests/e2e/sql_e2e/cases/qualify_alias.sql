-- QUALIFY filters on the alias of a window in the SELECT list.
SELECT id, k, row_number() OVER (PARTITION BY k ORDER BY id DESC NULLS LAST) AS rn FROM nulls WHERE id < 200 QUALIFY rn = 1 ORDER BY id ASC NULLS LAST
