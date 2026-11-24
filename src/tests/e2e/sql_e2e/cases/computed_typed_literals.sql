-- A query with no FROM: typed literals.
SELECT 1 AS one, 'x' AS s, 2.5 AS d, true AS t ORDER BY one ASC NULLS LAST
