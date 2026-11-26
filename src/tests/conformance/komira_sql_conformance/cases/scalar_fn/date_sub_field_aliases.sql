-- order: rows
SELECT k, date_sub('dayofweek', v, t), date_sub('weekday', v, t), date_sub('dayofyear', v, t), date_sub('julian', v, t), date_sub('weekofyear', v, t), date_sub('yearweek', v, t), date_sub('epoch', v, t), date_sub('m', v, t) FROM T
