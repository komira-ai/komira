-- order: rows
-- last_day of DATE and TIMESTAMP literals in leap and non-leap Februaries
SELECT k, last_day(DATE '2100-02-01'), last_day(DATE '2000-02-29'), last_day(DATE '2015-12-31'), last_day(TIMESTAMP '2028-02-03 10:11:12'), last_day(DATE '2024-02-10') FROM T
