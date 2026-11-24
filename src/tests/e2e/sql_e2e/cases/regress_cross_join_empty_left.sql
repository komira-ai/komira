-- CROSS JOIN whose left side has no row: no row, the header alone.
-- Catches rows of the right side emitted alone.
SELECT x.a AS a, y.bid AS bid, y.b AS b FROM (SELECT a FROM cross_a WHERE a < 0) AS x CROSS JOIN cross_b AS y ORDER BY a ASC NULLS LAST, bid ASC NULLS LAST
