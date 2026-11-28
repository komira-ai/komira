-- SELECT * beside a window function: every input column, then the window.
SELECT *, row_number() OVER (ORDER BY id ASC NULLS LAST) AS rn FROM join_left ORDER BY id ASC NULLS LAST
