-- order: rows
-- Aggregate shape over the exact-float table T, output columns pct
SELECT 100.0 * sum(dp * promo) / sum(dp) AS pct FROM T
