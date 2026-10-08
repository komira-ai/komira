-- order: none
-- not null: n, nv
-- Twin of the HAND case: with no grouping keys, zero input rows give one
-- row, COUNT 0 and every other aggregate NULL (§2.3). id < 0 holds for no
-- row of groups (ids 1 to 7).
SELECT COUNT(*) AS n, COUNT(v) AS nv, CAST(SUM(v) AS BIGINT) AS s, MAX(v) AS hi
FROM groups
WHERE id < CAST(0 AS BIGINT)
