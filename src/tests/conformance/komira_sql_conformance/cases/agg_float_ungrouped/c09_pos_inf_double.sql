-- order: rows
-- The six aggregates of the DOUBLE column over the set pos_inf
SELECT sum(d) AS s, avg(d) AS a, min(d) AS mn, max(d) AS mx, count(d) AS c, count(*) AS n FROM X WHERE grp = 'pos_inf'
