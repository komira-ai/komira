-- order: rows
-- Aggregate shape over the exact-float table T, output columns k1, k2, sq, sp, sd, aq, ap, ad, co
SELECT k1, k2, sum(qty) AS sq, sum(price) AS sp, sum(dp) AS sd, avg(qty) AS aq, avg(price) AS ap, avg(disc) AS ad, count(*) AS co FROM T WHERE qty <= 36.0 GROUP BY k1, k2
