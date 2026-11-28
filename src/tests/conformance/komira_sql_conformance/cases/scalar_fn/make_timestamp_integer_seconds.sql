-- order: rows
-- six-argument make_timestamp with an integer seconds argument, BIGINT and INTEGER parts, the hour taken modulo 24 in the second call
SELECT k, make_timestamp(yr, mo, dy, hr, mi, 0), make_timestamp(CAST(yr AS INTEGER), CAST(mo AS INTEGER), CAST(dy AS INTEGER), CAST(hr AS INTEGER) % 24, CAST(mi AS INTEGER), 7) FROM T
