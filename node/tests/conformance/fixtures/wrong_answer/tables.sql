-- The wrong-answer fixture's table W: three rows of a key, a text and a
-- DOUBLE, a NULL among the texts.
CREATE TABLE W (k BIGINT, s VARCHAR, d DOUBLE);
INSERT INTO W VALUES (1, 'a', '0.5'::DOUBLE), (2, NULL, '-2.25'::DOUBLE), (3, 'c', '1e300'::DOUBLE);
