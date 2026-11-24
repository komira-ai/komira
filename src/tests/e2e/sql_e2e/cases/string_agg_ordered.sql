-- string_agg with its own ORDER BY.
SELECT k, string_agg(s, ',' ORDER BY id ASC NULLS LAST) AS words FROM nulls WHERE id < 40 GROUP BY k ORDER BY k ASC NULLS FIRST
