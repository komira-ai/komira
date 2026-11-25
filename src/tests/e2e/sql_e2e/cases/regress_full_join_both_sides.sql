-- FULL JOIN with a key on both sides, one on the left only, two on the right
-- only, and a left key matching two right rows. Catches unmatched rows of
-- either side dropped or NULL-padded wrong, and a matched pair emitted twice.
SELECT l.lk AS lk, l.lv AS lv, r.rk AS rk, r.rv AS rv FROM full_l AS l FULL JOIN full_r AS r ON l.lk = r.rk ORDER BY lv ASC NULLS LAST, rv ASC NULLS LAST
