-- QUALIFY keeps the top two rows of each k (a BETWEEN bound on row_number).
SELECT id, k FROM nulls WHERE id < 100 QUALIFY row_number() OVER (PARTITION BY k ORDER BY id DESC NULLS LAST) BETWEEN 1 AND 2 ORDER BY id ASC NULLS LAST
