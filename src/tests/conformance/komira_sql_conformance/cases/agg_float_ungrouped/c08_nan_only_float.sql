-- order: rows
-- The six aggregates of the FLOAT column over the set nan_only
SELECT sum(f) AS s, avg(f) AS a, min(f) AS mn, max(f) AS mx, count(f) AS c, count(*) AS n FROM X WHERE grp = 'nan_only'
