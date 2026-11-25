-- FULL JOIN whose right side has no row: every left row, right columns NULL.
SELECT l.lk AS lk, l.lv AS lv, r.rk AS rk, r.rv AS rv FROM full_l AS l FULL JOIN (SELECT rk, rv FROM full_r WHERE rk < 0) AS r ON l.lk = r.rk ORDER BY lv ASC NULLS LAST
