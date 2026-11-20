-- order: query
-- Surface probe: non ascii group key
SELECT k, sum(v) AS v FROM fx_weirdstr GROUP BY k ORDER BY k
