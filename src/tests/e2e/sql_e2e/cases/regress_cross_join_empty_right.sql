-- CROSS JOIN whose right side has no row: no row, the header alone.
-- Catches rows of the left side emitted alone.
SELECT x.a AS a, y.bid AS bid, y.b AS b FROM cross_a AS x CROSS JOIN (SELECT bid, b FROM cross_b WHERE b < 0) AS y ORDER BY a ASC NULLS LAST, bid ASC NULLS LAST
