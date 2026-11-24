-- A global aggregate over a Parquet scan: one row, the aggregates in the
-- order asked. Catches a wrong sum, min, max, count or mean, or a result
-- that is not exactly one row.
SELECT sum(v) AS s, min(v) AS mn, max(v) AS mx, count(*) AS n, avg(f) AS m FROM agg_scalar ORDER BY s ASC NULLS LAST
