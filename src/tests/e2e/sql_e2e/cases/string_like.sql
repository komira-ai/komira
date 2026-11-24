-- LIKE with % and _.
SELECT id, s FROM nulls WHERE (s LIKE '%a%' OR s LIKE '_e%') AND id < 1000 ORDER BY id ASC NULLS LAST
