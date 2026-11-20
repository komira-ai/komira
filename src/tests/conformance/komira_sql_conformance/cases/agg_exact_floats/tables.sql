-- One 50000-row table T of DOUBLE columns whose every value is a small dyadic
-- rational, so every sum is exact whatever order it is added in. Keys: g has 10
-- values, k1 3 values, k2 2 values (varying independently of g). The rows are
-- built by an expression over range(), not listed.
CREATE TABLE T (g BIGINT, k1 VARCHAR, k2 VARCHAR, price DOUBLE, disc DOUBLE, qty DOUBLE, promo DOUBLE, dp DOUBLE);
INSERT INTO T
SELECT g, k1, k2, price, disc, qty, promo, price * (1.0::DOUBLE - disc)
FROM (
    SELECT
        (i % 10)::BIGINT AS g,
        (['A', 'N', 'R'])[1 + (i % 3)] AS k1,
        (['F', 'O'])[1 + ((i // 7) % 2)] AS k2,
        1.0::DOUBLE + ((i * 7) % 16384)::DOUBLE * 0.25::DOUBLE AS price,
        ((i // 3) % 5)::DOUBLE * 0.0625::DOUBLE AS disc,
        (1 + (((i * 11) % 50) * ((i * 11) % 50)) // 10)::DOUBLE AS qty,
        ((i // 11) % 2)::DOUBLE AS promo,
        i
    FROM range(50000) AS r(i)
    ORDER BY i
);
