-- order: rows
-- The six aggregates of the FLOAT column over no row (no row of X is in the set none)
SELECT sum(f) AS s, avg(f) AS a, min(f) AS mn, max(f) AS mx, count(f) AS c, count(*) AS n FROM X WHERE grp = 'none'
