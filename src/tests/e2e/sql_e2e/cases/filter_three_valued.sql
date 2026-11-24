-- AND, OR and NOT over every pair of TRUE, FALSE and NULL.
SELECT id, b1, b2, b1 AND b2 AS b_and, b1 OR b2 AS b_or, NOT b1 AS b_not FROM nulls WHERE id < 9 ORDER BY id ASC NULLS LAST
