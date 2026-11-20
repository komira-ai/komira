-- order: query
-- Surface probe: group after agg
SELECT s, count(*) AS c FROM ( SELECT n_regionkey, sum(n_nationkey) AS s FROM fx_nation GROUP BY n_regionkey) GROUP BY s ORDER BY s
