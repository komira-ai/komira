-- CAST of text DuckDB reads as BIGINT, INTEGER and DOUBLE alike: a sign,
-- surrounding whitespace, a fraction rounded half away from zero on its
-- first digit ('2.5' is 3, '-2.5' is -3), an exponent ('1e3'), an underscore
-- between digits and leading zeros.
SELECT id, txt, CAST(txt AS BIGINT) AS b, CAST(txt AS INTEGER) AS i, CAST(txt AS DOUBLE) AS d FROM cast_text WHERE id <= 20 ORDER BY id ASC NULLS LAST
