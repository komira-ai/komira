-- The generator the datasets are built from: no random() and no clock.
-- draw(i, s) is row i's value of stream s, an integer in [0, 2^64): the
-- splitmix64 finalizer over (i, s), in UHUGEINT so no product overflows.
-- It is a function of its arguments and nothing else, so every run, every
-- worker and every thread count builds the same rows. (DuckDB's
-- setseed()/random() is not used: nothing promises its sequence across
-- releases.)
CREATE MACRO mul64(x, k) AS (CAST(x AS UHUGEINT) * CAST(k AS UHUGEINT)) % CAST(18446744073709551616 AS UHUGEINT);
CREATE MACRO xs(x, n) AS xor(x, x >> n);
CREATE MACRO draw(i, s) AS xs(mul64(xs(mul64(xs(
    mul64(CAST(i AS UHUGEINT) * 1000003 + CAST(s AS UHUGEINT) * 7919 + 1, 11400714819323198485),
    30), 13787848793156543929), 27), 10723151780598845931), 31);

-- The cell of row i: the i-th special value (a typed list, 1-based) while
-- there are any, then NULL on every eighth row, else the drawn value.
CREATE MACRO cell(i, specials, value) AS
    CASE WHEN i < len(specials) THEN specials[i + 1] WHEN i % 8 = 7 THEN NULL ELSE value END;

-- A decimal of precision p and scale s from an integer n with |n| < 10^p,
-- spelt as text and cast (no float in between).
CREATE MACRO pow10(e) AS CAST('1' || repeat('0', e) AS UHUGEINT);
CREATE MACRO dec_text(n, s) AS
    (CASE WHEN n < 0 THEN '-' ELSE '' END) || CAST(CAST(abs(n) AS UHUGEINT) // pow10(s) AS VARCHAR)
    || '.' || lpad(CAST(CAST(abs(n) AS UHUGEINT) % pow10(s) AS VARCHAR), s, '0');

-- A finite float from its decimal spelling: `digits` significant digits and
-- a power of ten, parsed by DuckDB's string-to-float cast (correctly
-- rounded, independent of the worker's libm).
CREATE MACRO float_text(i, s, digits, lo_exp, exp_span) AS
    (CASE WHEN draw(i, s) % 2 = 0 THEN '-' ELSE '' END)
    || CAST(pow10(digits - 1) + draw(i, s + 1) % (CAST(9 AS UHUGEINT) * pow10(digits - 1)) AS VARCHAR)
    || 'e' || CAST(lo_exp + CAST(draw(i, s + 2) % exp_span AS INTEGER) AS VARCHAR);

-- Text from a fixed alphabet that holds CSV and escape syntax and 2-, 3-
-- and 4-byte UTF-8, 0 to 12 characters long.
CREATE MACRO alphabet() AS 'abcxyz ABC019,"''' || chr(10) || chr(9) || '\éß世界😀';
-- Every modulus of a draw is a UHUGEINT or an integer literal: UHUGEINT
-- % BIGINT is computed in DOUBLE, which keeps 53 of the 64 bits (with
-- length() as a BIGINT the text came out of three letters).
CREATE MACRO draw_text(text_row, text_stream) AS (
    SELECT coalesce(string_agg(substring(alphabet(), CAST(draw(text_row * 16 + p, text_stream + 1) % CAST(length(alphabet()) AS UHUGEINT) AS BIGINT) + 1, 1), '' ORDER BY p), '')
    FROM range(CAST(draw(text_row, text_stream) % 13 AS BIGINT)) AS t(p));

CREATE MACRO words() AS ['apple', 'Banana', 'cherry', 'éclair', 'fig'];
CREATE MACRO draw_word(i, s) AS words()[CAST(draw(i, s) % 5 AS BIGINT) + 1];
