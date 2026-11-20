-- order: rows
-- `in (subquery)` whose body carries its own where
SELECT k FROM T WHERE k IN (SELECT j FROM U WHERE w > 150)
