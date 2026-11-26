-- order: rows
-- make_date over the same columns cast to INTEGER
SELECT k, make_date(CAST(yr AS INTEGER), CAST(mo AS INTEGER), CAST(dy AS INTEGER)) FROM T
