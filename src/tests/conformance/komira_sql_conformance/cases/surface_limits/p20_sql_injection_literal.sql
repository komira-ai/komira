-- order: query
-- Surface probe: sql injection literal
SELECT k, v FROM fx_weirdstr WHERE k = 'x'' OR 1=1 --' ORDER BY v
