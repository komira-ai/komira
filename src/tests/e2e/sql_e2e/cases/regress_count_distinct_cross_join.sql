-- count(DISTINCT) per group across a CROSS JOIN (3 x 3 rows, b holds 20
-- twice). Catches a distinct count taken before the join or over the whole
-- product, and a cross join with rows missing or repeated.
SELECT x.a AS a, count(*) AS n, count(DISTINCT y.b) AS db FROM cross_a AS x CROSS JOIN cross_b AS y GROUP BY x.a ORDER BY a ASC NULLS LAST
