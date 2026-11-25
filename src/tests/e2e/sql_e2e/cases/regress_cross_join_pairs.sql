-- CROSS JOIN of 3 rows by 3 rows: every pair once, both sides' columns.
-- Catches a missing or repeated pair and a column taken from the wrong side.
SELECT x.a AS a, y.bid AS bid, y.b AS b FROM cross_a AS x CROSS JOIN cross_b AS y ORDER BY a ASC NULLS LAST, bid ASC NULLS LAST
