-- order: rows
SELECT k, date_diff('hrs', v, t), datediff('mon', v, t), date_diff('d', t, v) FROM T
