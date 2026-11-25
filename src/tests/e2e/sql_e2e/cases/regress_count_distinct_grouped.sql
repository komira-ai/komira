-- count(DISTINCT) per group: duplicates, a NULL beside values, one value
-- repeated, NULLs only. Catches rows counted for distinct values, a NULL
-- counted as a value, and a group whose distinct count is 0 dropped.
SELECT key, count(DISTINCT val) AS cd, count(val) AS c, count(*) AS n FROM distinct_pairs GROUP BY key ORDER BY key ASC NULLS LAST
