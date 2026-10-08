-- order: none
-- Twin of the HAND case: SUM over a group of only NULLs is NULL (§2.2).
-- SUM of INT64 is INT64 in the plan (§8.1), HUGEINT in DuckDB, hence the
-- CAST.
SELECT k, CAST(SUM(v) AS BIGINT) AS s
FROM groups
GROUP BY k
ORDER BY k ASC NULLS LAST
