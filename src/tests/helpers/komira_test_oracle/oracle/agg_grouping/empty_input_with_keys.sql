-- order: none
-- not null: n
-- Twin of the HAND case: with grouping keys, zero input rows give zero
-- rows (§2.3).
SELECT k, COUNT(*) AS n
FROM groups
WHERE id < CAST(0 AS BIGINT)
GROUP BY k
ORDER BY k ASC NULLS LAST
