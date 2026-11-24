-- A global aggregate over a filtered scan (v >= 48 keeps 48 of 96 rows).
-- Catches a filter that never reaches the scan (sum 4560, count 96) and an
-- off-by-one at its bound.
SELECT sum(v) AS s, count(*) AS n, min(v) AS mn FROM agg_scalar WHERE v >= 48 ORDER BY n ASC NULLS LAST
