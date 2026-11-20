-- order: rows
-- Surface probe: non ascii literal filter
SELECT k, v FROM fx_weirdstr WHERE k = '日本語'
