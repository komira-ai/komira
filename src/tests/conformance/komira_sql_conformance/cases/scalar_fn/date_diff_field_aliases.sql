-- order: rows
SELECT k, date_diff('dow', v, t), date_diff('isodow', v, t), date_diff('doy', v, t), date_diff('julian', v, t), date_diff('weekofyear', v, t), date_diff('yearweek', v, t), date_diff('epoch', v, t), date_diff('m', v, t) FROM T
