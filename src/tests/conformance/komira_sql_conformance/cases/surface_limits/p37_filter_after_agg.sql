-- order: query
-- Surface probe: filter after agg
SELECT n_regionkey, sum(n_nationkey) AS n_nationkey FROM fx_nation GROUP BY n_regionkey HAVING sum(n_nationkey) > 30 ORDER BY n_regionkey
