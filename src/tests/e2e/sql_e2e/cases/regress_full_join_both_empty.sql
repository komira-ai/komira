-- FULL JOIN of two sides with no row: no row, the header alone.
SELECT l.lk AS lk, l.lv AS lv, r.rk AS rk, r.rv AS rv FROM (SELECT lk, lv FROM full_l WHERE lk < 0) AS l FULL JOIN (SELECT rk, rv FROM full_r WHERE rk < 0) AS r ON l.lk = r.rk ORDER BY lv ASC NULLS LAST, rv ASC NULLS LAST
