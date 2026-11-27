-- SELECT * with QUALIFY: one row per k, the lowest id, NULL keys together.
SELECT * FROM join_left QUALIFY row_number() OVER (PARTITION BY k ORDER BY id ASC NULLS LAST) = 1 ORDER BY id ASC NULLS LAST
