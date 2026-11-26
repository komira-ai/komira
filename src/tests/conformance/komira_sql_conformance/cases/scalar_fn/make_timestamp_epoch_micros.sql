-- order: rows
-- one-argument make_timestamp of a BIGINT of microseconds since the epoch
SELECT k, make_timestamp(m) FROM T
