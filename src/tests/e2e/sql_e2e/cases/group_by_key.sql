-- GROUP BY a key with a NULL group.
SELECT k, count(*) AS n, count(i32) AS ni, sum(i32) AS s, min(v) AS mn, max(v) AS mx FROM nulls GROUP BY k ORDER BY k ASC NULLS FIRST
