-- / over integers answers DOUBLE; % keeps the sign of the dividend.
SELECT id, i32 / 2 AS half, i32 % 3 AS rem, v / 4 AS quarter FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
