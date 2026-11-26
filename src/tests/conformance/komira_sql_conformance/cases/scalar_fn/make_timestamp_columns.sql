-- order: rows
-- six-argument make_timestamp over the calendar columns: 24:00, 60 seconds, sub-microsecond seconds, NULL parts
SELECT k, make_timestamp(yr, mo, dy, hr, mi, sec) FROM T
