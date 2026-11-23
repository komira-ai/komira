-- The tables of test_run_sql_correlated, written by DuckDB in small row groups:
-- the eight tables of the TPC-H schema (column names and types as DuckDB's
-- dbgen writes them: INTEGER keys, DECIMAL(15,2) money and quantities, DATE,
-- VARCHAR), with rows made from the row number n so the six queries with
-- correlated subqueries (q2, q4, q17, q20, q21, q22) select rows and the cases
-- around them meet their boundaries. Derived from TPC-H; not comparable to
-- published TPC-H results.
--
-- What the rows hold on purpose:
--   * region and nation: the 5 regions and 25 nations of the TPC-H schema.
--   * supplier (40): n % 5 picks FRANCE (EUROPE), CANADA, SAUDI ARABIA, GERMANY
--     (EUROPE) or nation n % 25; s_acctbal repeats, so ORDER BY keys tie.
--   * part (60): 'forest%' names, '%BRASS' types, size 15, Brand#23 in a MED
--     BOX (parts 11 and 36), and parts 55 to 60 have no lineitem.
--   * partsupp: four suppliers per part (the TPC-H formula); ps_supplycost
--     ties at the minimum, so q2 keeps several suppliers of one part.
--   * customer (60): custkey a multiple of 3 has no order (q22's NOT EXISTS
--     holds); phone country codes 10 to 34; acctbal negative, zero and
--     positive.
--   * orders (200): o_custkey NULL where n % 37 = 36 and 61 (no customer)
--     where n % 53 = 52; dates around the q4 and q20 windows; orders with
--     n % 11 = 10 have no lineitem.
--   * lineitem: 1 to 7 lines per order, receipt after commit on some lines
--     only; l_suppkey NULL on line 3 of every 29th order.

COPY (
    SELECT
        CAST(r AS INTEGER) AS r_regionkey,
        CAST(['AFRICA', 'AMERICA', 'ASIA', 'EUROPE', 'MIDDLE EAST'][r + 1] AS VARCHAR) AS r_name,
        'region comment ' || CAST(r AS VARCHAR) AS r_comment
    FROM range(5) t(r)
) TO 'region.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2);

COPY (
    SELECT
        CAST(n AS INTEGER) AS n_nationkey,
        CAST([
            'ALGERIA', 'ARGENTINA', 'BRAZIL', 'CANADA', 'EGYPT', 'ETHIOPIA',
            'FRANCE', 'GERMANY', 'INDIA', 'INDONESIA', 'IRAN', 'IRAQ', 'JAPAN',
            'JORDAN', 'KENYA', 'MOROCCO', 'MOZAMBIQUE', 'PERU', 'CHINA',
            'ROMANIA', 'SAUDI ARABIA', 'VIETNAM', 'RUSSIA', 'UNITED KINGDOM',
            'UNITED STATES'
        ][n + 1] AS VARCHAR) AS n_name,
        CAST([0, 1, 1, 1, 4, 0, 3, 3, 2, 2, 4, 4, 2, 4, 0, 0, 0, 1, 2, 3, 4, 2, 3, 3, 1][n + 1] AS INTEGER) AS n_regionkey,
        'nation comment ' || CAST(n AS VARCHAR) AS n_comment
    FROM range(25) t(n)
) TO 'nation.parquet' (FORMAT parquet, ROW_GROUP_SIZE 8);

COPY (
    SELECT
        CAST(n AS INTEGER) AS s_suppkey,
        'Supplier#' || lpad(CAST(n AS VARCHAR), 9, '0') AS s_name,
        'address ' || CAST(n * 7 AS VARCHAR) AS s_address,
        CAST(CASE n % 5 WHEN 0 THEN 6 WHEN 1 THEN 3 WHEN 2 THEN 20 WHEN 3 THEN 7 ELSE n % 25 END AS INTEGER) AS s_nationkey,
        CAST(10 + n % 25 AS VARCHAR) || '-' || lpad(CAST(n * 13 % 1000 AS VARCHAR), 3, '0') || '-555-0100' AS s_phone,
        CAST(((n * 7) % 13) * 100.5 - 250 AS DECIMAL(15, 2)) AS s_acctbal,
        'supplier comment ' || CAST(n AS VARCHAR) AS s_comment
    FROM range(1, 41) t(n)
) TO 'supplier.parquet' (FORMAT parquet, ROW_GROUP_SIZE 16);

COPY (
    SELECT
        CAST(n AS INTEGER) AS p_partkey,
        CASE WHEN n % 6 = 0 THEN 'forest green ' ELSE 'blue lavender ' END || CAST(n AS VARCHAR) AS p_name,
        'Manufacturer#' || CAST(n % 5 + 1 AS VARCHAR) AS p_mfgr,
        'Brand#' || CAST(n % 5 + 1 AS VARCHAR) || CAST((n // 5) % 5 + 1 AS VARCHAR) AS p_brand,
        CAST(['STANDARD POLISHED BRASS', 'LARGE BRUSHED STEEL', 'ECONOMY ANODIZED BRASS', 'SMALL PLATED TIN', 'BRASS PROMO TIN'][n % 5 + 1] AS VARCHAR) AS p_type,
        CAST(CASE WHEN n % 3 = 0 THEN 15 ELSE n % 50 + 1 END AS INTEGER) AS p_size,
        CASE WHEN n % 10 IN (1, 6) THEN 'MED BOX' WHEN n % 10 = 2 THEN 'LG BOX' ELSE 'SM CASE' END AS p_container,
        CAST(900 + n * 1.5 AS DECIMAL(15, 2)) AS p_retailprice,
        'part comment ' || CAST(n AS VARCHAR) AS p_comment
    FROM range(1, 61) t(n)
) TO 'part.parquet' (FORMAT parquet, ROW_GROUP_SIZE 16);

COPY (
    SELECT
        CAST(p AS INTEGER) AS ps_partkey,
        CAST((p + i * (10 + (p - 1) // 40)) % 40 + 1 AS INTEGER) AS ps_suppkey,
        CAST((p * 7 + i * 3) % 40 + 1 AS INTEGER) AS ps_availqty,
        CAST(((p * i) % 3) * 100 + 1.5 AS DECIMAL(15, 2)) AS ps_supplycost,
        'partsupp comment ' || CAST(p * 4 + i AS VARCHAR) AS ps_comment
    FROM range(1, 61) a(p), range(4) b(i)
    ORDER BY p, i
) TO 'partsupp.parquet' (FORMAT parquet, ROW_GROUP_SIZE 32);

COPY (
    SELECT
        CAST(n AS INTEGER) AS c_custkey,
        'Customer#' || lpad(CAST(n AS VARCHAR), 9, '0') AS c_name,
        'street ' || CAST(n * 11 AS VARCHAR) AS c_address,
        CAST(n % 25 AS INTEGER) AS c_nationkey,
        CAST(10 + n % 25 AS VARCHAR) || '-' || lpad(CAST(n * 17 % 1000 AS VARCHAR), 3, '0') || '-555-0199' AS c_phone,
        CAST(CASE WHEN n % 17 = 0 THEN 0 ELSE ((n * 53) % 1500) - 300 + 0.75 END AS DECIMAL(15, 2)) AS c_acctbal,
        CAST(['AUTOMOBILE', 'BUILDING', 'FURNITURE', 'HOUSEHOLD', 'MACHINERY'][n % 5 + 1] AS VARCHAR) AS c_mktsegment,
        'customer comment ' || CAST(n AS VARCHAR) AS c_comment
    FROM range(1, 61) t(n)
) TO 'customer.parquet' (FORMAT parquet, ROW_GROUP_SIZE 16);

CREATE TABLE orders_rows AS
    SELECT
        n,
        CAST(n * 4 + 1 AS INTEGER) AS o_orderkey,
        CAST(CASE
            WHEN n % 37 = 36 THEN NULL
            WHEN n % 53 = 52 THEN 61
            ELSE (n * 7) % 40 + ((n * 7) % 40) // 2 + 1
        END AS INTEGER) AS o_custkey,
        CAST(['F', 'O', 'P'][n % 3 + 1] AS VARCHAR) AS o_orderstatus,
        CAST(1000 + n * 12.5 AS DECIMAL(15, 2)) AS o_totalprice,
        DATE '1993-05-01' + CAST((n * 3) % 400 AS INTEGER) AS o_orderdate,
        CAST(['1-URGENT', '2-HIGH', '3-MEDIUM', '4-NOT SPECIFIED', '5-LOW'][n % 5 + 1] AS VARCHAR) AS o_orderpriority,
        'Clerk#' || lpad(CAST(n % 10 AS VARCHAR), 9, '0') AS o_clerk,
        CAST(0 AS INTEGER) AS o_shippriority,
        'order comment ' || CAST(n AS VARCHAR) AS o_comment
    FROM range(200) t(n);

COPY (
    SELECT o_orderkey, o_custkey, o_orderstatus, o_totalprice, o_orderdate,
        o_orderpriority, o_clerk, o_shippriority, o_comment
    FROM orders_rows ORDER BY n
) TO 'orders.parquet' (FORMAT parquet, ROW_GROUP_SIZE 64);

COPY (
    SELECT
        o.o_orderkey AS l_orderkey,
        CAST((o.n * 13 + j * 7) % 54 + 1 AS INTEGER) AS l_partkey,
        CAST(CASE
            WHEN o.n % 29 = 0 AND j = 2 THEN NULL
            ELSE (((o.n * 13 + j * 7) % 54 + 1) + ((o.n + j) % 4) * (10 + ((o.n * 13 + j * 7) % 54) // 40)) % 40 + 1
        END AS INTEGER) AS l_suppkey,
        CAST(j + 1 AS INTEGER) AS l_linenumber,
        CAST((o.n * 3 + j * 11) % 50 + 1 AS DECIMAL(15, 2)) AS l_quantity,
        CAST(((o.n * 3 + j * 11) % 50 + 1) * (901.5 + ((o.n * 13 + j * 7) % 54) * 1.5) AS DECIMAL(15, 2)) AS l_extendedprice,
        CAST((j % 10) / 100.0 AS DECIMAL(15, 2)) AS l_discount,
        CAST(((o.n + j) % 9) / 100.0 AS DECIMAL(15, 2)) AS l_tax,
        CAST(['A', 'N', 'R'][(o.n + j) % 3 + 1] AS VARCHAR) AS l_returnflag,
        CAST(['F', 'O'][(o.n + j) % 2 + 1] AS VARCHAR) AS l_linestatus,
        o.o_orderdate + CAST((j * 17 + o.n) % 120 + 1 AS INTEGER) AS l_shipdate,
        o.o_orderdate + CAST((o.n * 5 + j * 3) % 60 + 30 AS INTEGER) AS l_commitdate,
        o.o_orderdate + CAST((j * 17 + o.n) % 120 + 1 + (o.n + j * 2) % 50 + 1 AS INTEGER) AS l_receiptdate,
        CAST(['DELIVER IN PERSON', 'COLLECT COD', 'NONE', 'TAKE BACK RETURN'][(o.n + j) % 4 + 1] AS VARCHAR) AS l_shipinstruct,
        CAST(['AIR', 'MAIL', 'SHIP', 'TRUCK', 'RAIL', 'FOB', 'REG AIR'][(o.n * 3 + j) % 7 + 1] AS VARCHAR) AS l_shipmode,
        'lineitem comment ' || CAST(o.n * 7 + j AS VARCHAR) AS l_comment
    FROM orders_rows o, range(7) b(j)
    WHERE j < CASE WHEN o.n % 11 = 10 THEN 0 ELSE o.n % 7 + 1 END
    ORDER BY o.n, j
) TO 'lineitem.parquet' (FORMAT parquet, ROW_GROUP_SIZE 128);
