-- order: query
-- Surface probe: int literal on int group key
SELECT l_linenumber, count(l_orderkey) AS l_orderkey FROM fx_lineitem WHERE l_linenumber >= 4 GROUP BY l_linenumber ORDER BY l_linenumber
