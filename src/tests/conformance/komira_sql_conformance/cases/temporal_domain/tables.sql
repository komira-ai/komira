-- The temporal-domain tables. T holds one timestamp and the same civil date as a date,
-- for years before the common era, the year-zero boundary, century and leap-year rules,
-- week-year boundaries that differ from the calendar year, the epoch and the instant
-- just before it, and one all-NULL row. N is a timestamp column with no live value.
-- DXIN holds dates spread across the whole date range by day count. PMS, PUS and PNS hold
-- the same few instants at millisecond, microsecond and nanosecond precision (the
-- millisecond one stores whole milliseconds, floored), including one microsecond before
-- the epoch so a sub-second field read from a negative count is distinguished.
CREATE TABLE T (k BIGINT, ts TIMESTAMP, dt DATE);
INSERT INTO T VALUES
    (0, make_timestamp(-63549316800000000), DATE '1970-01-01' + -735525),
    (1, make_timestamp(-63556012800000000), DATE '1970-01-01' + -735602),
    (2, make_timestamp(-62167219200000001), DATE '1970-01-01' + -719529),
    (3, make_timestamp(-62167219200000000), DATE '1970-01-01' + -719528),
    (4, make_timestamp(-62135683200000000), DATE '1970-01-01' + -719163),
    (5, make_timestamp(-62135596800000000), DATE '1970-01-01' + -719162),
    (6, make_timestamp(-93708489600000000), DATE '1970-01-01' + -1084589),
    (7, make_timestamp(-125312659200000000), DATE '1970-01-01' + -1450378),
    (8, make_timestamp(-2203891200000001), DATE '1970-01-01' + -25509),
    (9, make_timestamp(-2203891200000000), DATE '1970-01-01' + -25508),
    (10, make_timestamp(951825600000000), DATE '1970-01-01' + 11016),
    (11, make_timestamp(4107456000000000), DATE '1970-01-01' + 47540),
    (12, make_timestamp(1582934400000000), DATE '1970-01-01' + 18321),
    (13, make_timestamp(-1), DATE '1970-01-01' + -1),
    (14, make_timestamp(0), DATE '1970-01-01' + 0),
    (15, make_timestamp(1609484889000500), DATE '1970-01-01' + 18628),
    (16, make_timestamp(1577664000000000), DATE '1970-01-01' + 18260),
    (17, make_timestamp(1609372800000000), DATE '1970-01-01' + 18627),
    (18, CAST(NULL AS TIMESTAMP), CAST(NULL AS DATE)),
    (19, make_timestamp(-14182940000000), DATE '1970-01-01' + -165),
    (20, make_timestamp(1861919999999999), DATE '1970-01-01' + 21549),
    (21, make_timestamp(1861920000000000), DATE '1970-01-01' + 21550),
    (22, make_timestamp(-63550656000000000), DATE '1970-01-01' + -735540),
    (23, make_timestamp(-65317881600000000), DATE '1970-01-01' + -755994),
    (24, make_timestamp(-74784902400000000), DATE '1970-01-01' + -865566);
CREATE TABLE N (k BIGINT, ts TIMESTAMP);
INSERT INTO N VALUES
    (0, CAST(NULL AS TIMESTAMP)),
    (1, CAST(NULL AS TIMESTAMP)),
    (2, CAST(NULL AS TIMESTAMP)),
    (3, CAST(NULL AS TIMESTAMP));
CREATE TABLE DXIN (k BIGINT, dt DATE);
INSERT INTO DXIN VALUES
    (0, DATE '1970-01-01' + (0)),
    (1, DATE '1970-01-01' + (-719528)),
    (2, DATE '1970-01-01' + (-719163)),
    (3, DATE '1970-01-01' + (-735525)),
    (4, DATE '1970-01-01' + (1000000)),
    (5, DATE '1970-01-01' + (106751991)),
    (6, DATE '1970-01-01' + (2147483646)),
    (7, DATE '1970-01-01' + (-2147483646)),
    (8, DATE '1970-01-01' + (-2147483648));
CREATE TABLE PMS (k BIGINT, t TIMESTAMP_MS);
INSERT INTO PMS VALUES
    (0, CAST(make_timestamp(0) AS TIMESTAMP_MS)),
    (1, CAST(make_timestamp(-1000) AS TIMESTAMP_MS)),
    (2, CAST(make_timestamp(-1000) AS TIMESTAMP_MS)),
    (3, CAST(make_timestamp(1609484889000000) AS TIMESTAMP_MS)),
    (4, CAST(make_timestamp(-14182940000000) AS TIMESTAMP_MS)),
    (5, NULL);
CREATE TABLE PUS (k BIGINT, t TIMESTAMP);
INSERT INTO PUS VALUES
    (0, make_timestamp(0)),
    (1, make_timestamp(-1)),
    (2, make_timestamp(-1000)),
    (3, make_timestamp(1609484889000500)),
    (4, make_timestamp(-14182940000000)),
    (5, NULL);
CREATE TABLE PNS (k BIGINT, t TIMESTAMP_NS);
INSERT INTO PNS VALUES
    (0, CAST(make_timestamp(0) AS TIMESTAMP_NS)),
    (1, CAST(make_timestamp(-1) AS TIMESTAMP_NS)),
    (2, CAST(make_timestamp(-1000) AS TIMESTAMP_NS)),
    (3, CAST(make_timestamp(1609484889000500) AS TIMESTAMP_NS)),
    (4, CAST(make_timestamp(-14182940000000) AS TIMESTAMP_NS)),
    (5, NULL);
