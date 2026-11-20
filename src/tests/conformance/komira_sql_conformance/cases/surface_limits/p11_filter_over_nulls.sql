-- order: rows
-- Surface probe: filter over nulls
SELECT k, v FROM fx_nulls WHERE v > 1.5
