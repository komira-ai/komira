-- A query with no FROM: literals of several types.
SELECT 1 AS one, 'x' AS s, CAST(NULL AS INTEGER) AS n, 2.5 AS d, true AS t ORDER BY one ASC NULLS LAST
