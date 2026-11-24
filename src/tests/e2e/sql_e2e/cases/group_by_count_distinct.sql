-- count(DISTINCT) per group.
SELECT k, count(DISTINCT s) AS ds FROM nulls GROUP BY k ORDER BY k ASC NULLS FIRST
