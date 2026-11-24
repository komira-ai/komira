-- CASE WHEN with an ELSE, NULL falling to the ELSE.
SELECT id, CASE WHEN i32 < 0 THEN 'neg' WHEN i32 = 0 THEN 'zero' WHEN i32 > 0 THEN 'pos' ELSE 'null' END AS sign FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
