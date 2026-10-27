# The datasets the suites expect, as data. Each table is a list of
# `name type` pairs (schema.columns_of).

from .schema import Dataset, Table, columns_of

comptime DATASET_TPCH = "tpch"
"""The eight TPC-H tables with the types of the TPC-H specification."""

comptime DATASET_CLICKBENCH = "clickbench"
"""The ClickBench `hits` table: 105 columns."""

comptime DATASET_H2O_GROUPBY = "h2o_groupby"
"""The h2o groupby table `x`."""

comptime DATASET_H2O_JOIN = "h2o_join"
"""The h2o join tables `x`, `small`, `medium` and `big`."""

comptime _REGION = "r_regionkey INTEGER; r_name CHAR(25); r_comment VARCHAR(152)"
comptime _NATION = (
    "n_nationkey INTEGER; n_name CHAR(25); n_regionkey INTEGER; "
    "n_comment VARCHAR(152)"
)
comptime _PART = (
    "p_partkey INTEGER; p_name VARCHAR(55); p_mfgr CHAR(25); "
    "p_brand CHAR(10); p_type VARCHAR(25); p_size INTEGER; "
    "p_container CHAR(10); p_retailprice DECIMAL(15,2); "
    "p_comment VARCHAR(23)"
)
comptime _SUPPLIER = (
    "s_suppkey INTEGER; s_name CHAR(25); s_address VARCHAR(40); "
    "s_nationkey INTEGER; s_phone CHAR(15); s_acctbal DECIMAL(15,2); "
    "s_comment VARCHAR(101)"
)
comptime _PARTSUPP = (
    "ps_partkey INTEGER; ps_suppkey INTEGER; ps_availqty INTEGER; "
    "ps_supplycost DECIMAL(15,2); ps_comment VARCHAR(199)"
)
comptime _CUSTOMER = (
    "c_custkey INTEGER; c_name VARCHAR(25); c_address VARCHAR(40); "
    "c_nationkey INTEGER; c_phone CHAR(15); c_acctbal DECIMAL(15,2); "
    "c_mktsegment CHAR(10); c_comment VARCHAR(117)"
)
comptime _ORDERS = (
    "o_orderkey BIGINT; o_custkey INTEGER; o_orderstatus CHAR(1); "
    "o_totalprice DECIMAL(15,2); o_orderdate DATE; o_orderpriority CHAR(15); "
    "o_clerk CHAR(15); o_shippriority INTEGER; o_comment VARCHAR(79)"
)
comptime _LINEITEM = (
    "l_orderkey BIGINT; l_partkey INTEGER; l_suppkey INTEGER; "
    "l_linenumber INTEGER; l_quantity DECIMAL(15,2); "
    "l_extendedprice DECIMAL(15,2); l_discount DECIMAL(15,2); "
    "l_tax DECIMAL(15,2); l_returnflag CHAR(1); l_linestatus CHAR(1); "
    "l_shipdate DATE; l_commitdate DATE; l_receiptdate DATE; "
    "l_shipinstruct CHAR(25); l_shipmode CHAR(10); l_comment VARCHAR(44)"
)

comptime _HITS = (
    "WatchID BIGINT; JavaEnable SMALLINT; Title VARCHAR; GoodEvent SMALLINT; "
    "EventTime TIMESTAMP; EventDate DATE; CounterID INTEGER; ClientIP INTEGER; "
    "RegionID INTEGER; UserID BIGINT; CounterClass SMALLINT; OS SMALLINT; "
    "UserAgent SMALLINT; URL VARCHAR; Referer VARCHAR; IsRefresh SMALLINT; "
    "RefererCategoryID SMALLINT; RefererRegionID INTEGER; "
    "URLCategoryID SMALLINT; URLRegionID INTEGER; ResolutionWidth SMALLINT; "
    "ResolutionHeight SMALLINT; ResolutionDepth SMALLINT; FlashMajor SMALLINT; "
    "FlashMinor SMALLINT; FlashMinor2 VARCHAR; NetMajor SMALLINT; "
    "NetMinor SMALLINT; UserAgentMajor SMALLINT; UserAgentMinor VARCHAR(255); "
    "CookieEnable SMALLINT; JavascriptEnable SMALLINT; IsMobile SMALLINT; "
    "MobilePhone SMALLINT; MobilePhoneModel VARCHAR; Params VARCHAR; "
    "IPNetworkID INTEGER; TraficSourceID SMALLINT; SearchEngineID SMALLINT; "
    "SearchPhrase VARCHAR; AdvEngineID SMALLINT; IsArtifical SMALLINT; "
    "WindowClientWidth SMALLINT; WindowClientHeight SMALLINT; "
    "ClientTimeZone SMALLINT; ClientEventTime TIMESTAMP; "
    "SilverlightVersion1 SMALLINT; SilverlightVersion2 SMALLINT; "
    "SilverlightVersion3 INTEGER; SilverlightVersion4 SMALLINT; "
    "PageCharset VARCHAR; CodeVersion INTEGER; IsLink SMALLINT; "
    "IsDownload SMALLINT; IsNotBounce SMALLINT; FUniqID BIGINT; "
    "OriginalURL VARCHAR; HID INTEGER; IsOldCounter SMALLINT; "
    "IsEvent SMALLINT; IsParameter SMALLINT; DontCountHits SMALLINT; "
    "WithHash SMALLINT; HitColor CHAR; LocalEventTime TIMESTAMP; "
    "Age SMALLINT; Sex SMALLINT; Income SMALLINT; Interests SMALLINT; "
    "Robotness SMALLINT; RemoteIP INTEGER; WindowName INTEGER; "
    "OpenerName INTEGER; HistoryLength SMALLINT; BrowserLanguage VARCHAR; "
    "BrowserCountry VARCHAR; SocialNetwork VARCHAR; SocialAction VARCHAR; "
    "HTTPError SMALLINT; SendTiming INTEGER; DNSTiming INTEGER; "
    "ConnectTiming INTEGER; ResponseStartTiming INTEGER; "
    "ResponseEndTiming INTEGER; FetchTiming INTEGER; "
    "SocialSourceNetworkID SMALLINT; SocialSourcePage VARCHAR; "
    "ParamPrice BIGINT; ParamOrderID VARCHAR; ParamCurrency VARCHAR; "
    "ParamCurrencyID SMALLINT; OpenstatServiceName VARCHAR; "
    "OpenstatCampaignID VARCHAR; OpenstatAdID VARCHAR; "
    "OpenstatSourceID VARCHAR; UTMSource VARCHAR; UTMMedium VARCHAR; "
    "UTMCampaign VARCHAR; UTMContent VARCHAR; UTMTerm VARCHAR; "
    "FromTag VARCHAR; HasGCLID SMALLINT; RefererHash BIGINT; URLHash BIGINT; "
    "CLID INTEGER"
)

comptime _H2O_GROUPBY_X = (
    "id1 VARCHAR; id2 VARCHAR; id3 VARCHAR; id4 INTEGER; id5 INTEGER; "
    "id6 INTEGER; v1 INTEGER; v2 INTEGER; v3 DOUBLE"
)
comptime _H2O_JOIN_X = (
    "id1 INTEGER; id2 INTEGER; id3 INTEGER; id4 VARCHAR; id5 VARCHAR; "
    "id6 VARCHAR; v1 DOUBLE"
)
comptime _H2O_JOIN_SMALL = "id1 INTEGER; id4 VARCHAR; v2 DOUBLE"
comptime _H2O_JOIN_MEDIUM = (
    "id1 INTEGER; id2 INTEGER; id4 VARCHAR; id5 VARCHAR; v2 DOUBLE"
)
comptime _H2O_JOIN_BIG = (
    "id1 INTEGER; id2 INTEGER; id3 INTEGER; id4 VARCHAR; id5 VARCHAR; "
    "id6 VARCHAR; v2 DOUBLE"
)


def _table(name: String, spec: String) -> Table:
    return Table(name.copy(), columns_of(spec))


def tpch_dataset() -> Dataset:
    var tables = List[Table]()
    tables.append(_table("region", _REGION))
    tables.append(_table("nation", _NATION))
    tables.append(_table("part", _PART))
    tables.append(_table("supplier", _SUPPLIER))
    tables.append(_table("partsupp", _PARTSUPP))
    tables.append(_table("customer", _CUSTOMER))
    tables.append(_table("orders", _ORDERS))
    tables.append(_table("lineitem", _LINEITEM))
    return Dataset(String(DATASET_TPCH), tables^)


def clickbench_dataset() -> Dataset:
    var tables = List[Table]()
    tables.append(_table("hits", _HITS))
    return Dataset(String(DATASET_CLICKBENCH), tables^)


def h2o_groupby_dataset() -> Dataset:
    var tables = List[Table]()
    tables.append(_table("x", _H2O_GROUPBY_X))
    return Dataset(String(DATASET_H2O_GROUPBY), tables^)


def h2o_join_dataset() -> Dataset:
    var tables = List[Table]()
    tables.append(_table("x", _H2O_JOIN_X))
    tables.append(_table("small", _H2O_JOIN_SMALL))
    tables.append(_table("medium", _H2O_JOIN_MEDIUM))
    tables.append(_table("big", _H2O_JOIN_BIG))
    return Dataset(String(DATASET_H2O_JOIN), tables^)
