-- order: query
-- Surface probe: repeat execution
SELECT n_regionkey, sum(n_nationkey) AS n_nationkey FROM fx_nation GROUP BY n_regionkey ORDER BY n_regionkey
