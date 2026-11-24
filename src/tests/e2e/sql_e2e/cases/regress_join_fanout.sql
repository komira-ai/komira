-- Many-to-many INNER JOIN, 100 probe rows per key against 10 build rows per
-- key (10000 rows); payloads distinct, so each row names one pair. Catches
-- the fan-out probe dropping, repeating or mispairing a pair.
SELECT p.jkey AS jkey, b.jkey AS jkey_right, p.left_val AS left_val, b.right_val AS right_val FROM fan_probe AS p JOIN fan_build AS b ON p.jkey = b.jkey ORDER BY left_val ASC NULLS LAST, right_val ASC NULLS LAST
