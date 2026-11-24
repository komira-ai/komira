-- FULL JOIN whose left side has no row: every right row, left columns NULL.
SELECT l.lk AS lk, l.lv AS lv, r.rk AS rk, r.rv AS rv FROM (SELECT lk, lv FROM full_l WHERE lk < 0) AS l FULL JOIN full_r AS r ON l.lk = r.rk ORDER BY rv ASC NULLS LAST
