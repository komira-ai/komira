-- order: query
-- Surface probe: all null column
SELECT k, sum(v) AS v FROM fx_allnull GROUP BY k ORDER BY k
