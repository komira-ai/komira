-- GROUP BY a key with a NULL group: counts and an integer sum.
SELECT k, count(*) AS n, count(i32) AS ni, sum(i32) AS s FROM nulls GROUP BY k ORDER BY k ASC NULLS FIRST
