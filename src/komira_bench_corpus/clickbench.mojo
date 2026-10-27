# The 43 queries of ClickBench, Q0 to Q42, in the text of the benchmark's
# DuckDB and ClickHouse query list, against the 105-column `hits` table
# (datasets.mojo). The ids are the benchmark's numbers: `q0` is `select count(*)
# from hits`.
#
# The text is taken from the ClickBench repository's `duckdb/queries.sql`,
# published under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0
# International licence (see README.md). The dates in the text are the
# benchmark's own filter values.

from .datasets import DATASET_CLICKBENCH
from .query import Query, Suite

comptime SUITE_CLICKBENCH = "clickbench"

comptime _Q0 = """SELECT COUNT(*) FROM hits"""

comptime _Q1 = """SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0"""

comptime _Q2 = """SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits"""

comptime _Q3 = """SELECT AVG(UserID) FROM hits"""

comptime _Q4 = """SELECT COUNT(DISTINCT UserID) FROM hits"""

comptime _Q5 = """SELECT COUNT(DISTINCT SearchPhrase) FROM hits"""

comptime _Q6 = """SELECT MIN(EventDate), MAX(EventDate) FROM hits"""

comptime _Q7 = """SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDER BY COUNT(*) DESC"""

comptime _Q8 = """SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10"""

comptime _Q9 = """SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT UserID) FROM hits GROUP BY RegionID ORDER BY c DESC LIMIT 10"""

comptime _Q10 = """SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhoneModel ORDER BY u DESC LIMIT 10"""

comptime _Q11 = """SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhone, MobilePhoneModel ORDER BY u DESC LIMIT 10"""

comptime _Q12 = """SELECT SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10"""

comptime _Q13 = """SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY u DESC LIMIT 10"""

comptime _Q14 = """SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, SearchPhrase ORDER BY c DESC LIMIT 10"""

comptime _Q15 = """SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10"""

comptime _Q16 = """SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10"""

comptime _Q17 = """SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase LIMIT 10"""

comptime _Q18 = """SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, m, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10"""

comptime _Q19 = """SELECT UserID FROM hits WHERE UserID = 435090932899640449"""

comptime _Q20 = """SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%'"""

comptime _Q21 = """SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits WHERE URL LIKE '%google%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10"""

comptime _Q22 = """SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c, COUNT(DISTINCT UserID) FROM hits WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10"""

comptime _Q23 = """SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10"""

comptime _Q24 = """SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10"""

comptime _Q25 = """SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10"""

comptime _Q26 = """SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime, SearchPhrase LIMIT 10"""

comptime _Q27 = """SELECT CounterID, AVG(length(URL)) AS l, COUNT(*) AS c FROM hits WHERE URL <> '' GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25"""

comptime _Q28 = """SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\\.)?([^/]+)/.*$', '\\1') AS k, AVG(length(Referer)) AS l, COUNT(*) AS c, MIN(Referer) FROM hits WHERE Referer <> '' GROUP BY k HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25"""

comptime _Q29 = """SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), SUM(ResolutionWidth + 2), SUM(ResolutionWidth + 3), SUM(ResolutionWidth + 4), SUM(ResolutionWidth + 5), SUM(ResolutionWidth + 6), SUM(ResolutionWidth + 7), SUM(ResolutionWidth + 8), SUM(ResolutionWidth + 9), SUM(ResolutionWidth + 10), SUM(ResolutionWidth + 11), SUM(ResolutionWidth + 12), SUM(ResolutionWidth + 13), SUM(ResolutionWidth + 14), SUM(ResolutionWidth + 15), SUM(ResolutionWidth + 16), SUM(ResolutionWidth + 17), SUM(ResolutionWidth + 18), SUM(ResolutionWidth + 19), SUM(ResolutionWidth + 20), SUM(ResolutionWidth + 21), SUM(ResolutionWidth + 22), SUM(ResolutionWidth + 23), SUM(ResolutionWidth + 24), SUM(ResolutionWidth + 25), SUM(ResolutionWidth + 26), SUM(ResolutionWidth + 27), SUM(ResolutionWidth + 28), SUM(ResolutionWidth + 29), SUM(ResolutionWidth + 30), SUM(ResolutionWidth + 31), SUM(ResolutionWidth + 32), SUM(ResolutionWidth + 33), SUM(ResolutionWidth + 34), SUM(ResolutionWidth + 35), SUM(ResolutionWidth + 36), SUM(ResolutionWidth + 37), SUM(ResolutionWidth + 38), SUM(ResolutionWidth + 39), SUM(ResolutionWidth + 40), SUM(ResolutionWidth + 41), SUM(ResolutionWidth + 42), SUM(ResolutionWidth + 43), SUM(ResolutionWidth + 44), SUM(ResolutionWidth + 45), SUM(ResolutionWidth + 46), SUM(ResolutionWidth + 47), SUM(ResolutionWidth + 48), SUM(ResolutionWidth + 49), SUM(ResolutionWidth + 50), SUM(ResolutionWidth + 51), SUM(ResolutionWidth + 52), SUM(ResolutionWidth + 53), SUM(ResolutionWidth + 54), SUM(ResolutionWidth + 55), SUM(ResolutionWidth + 56), SUM(ResolutionWidth + 57), SUM(ResolutionWidth + 58), SUM(ResolutionWidth + 59), SUM(ResolutionWidth + 60), SUM(ResolutionWidth + 61), SUM(ResolutionWidth + 62), SUM(ResolutionWidth + 63), SUM(ResolutionWidth + 64), SUM(ResolutionWidth + 65), SUM(ResolutionWidth + 66), SUM(ResolutionWidth + 67), SUM(ResolutionWidth + 68), SUM(ResolutionWidth + 69), SUM(ResolutionWidth + 70), SUM(ResolutionWidth + 71), SUM(ResolutionWidth + 72), SUM(ResolutionWidth + 73), SUM(ResolutionWidth + 74), SUM(ResolutionWidth + 75), SUM(ResolutionWidth + 76), SUM(ResolutionWidth + 77), SUM(ResolutionWidth + 78), SUM(ResolutionWidth + 79), SUM(ResolutionWidth + 80), SUM(ResolutionWidth + 81), SUM(ResolutionWidth + 82), SUM(ResolutionWidth + 83), SUM(ResolutionWidth + 84), SUM(ResolutionWidth + 85), SUM(ResolutionWidth + 86), SUM(ResolutionWidth + 87), SUM(ResolutionWidth + 88), SUM(ResolutionWidth + 89) FROM hits"""

comptime _Q30 = """SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, ClientIP ORDER BY c DESC LIMIT 10"""

comptime _Q31 = """SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10"""

comptime _Q32 = """SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10"""

comptime _Q33 = """SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10"""

comptime _Q34 = """SELECT 1, URL, COUNT(*) AS c FROM hits GROUP BY 1, URL ORDER BY c DESC LIMIT 10"""

comptime _Q35 = """SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c FROM hits GROUP BY ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3 ORDER BY c DESC LIMIT 10"""

comptime _Q36 = """SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND URL <> '' GROUP BY URL ORDER BY PageViews DESC LIMIT 10"""

comptime _Q37 = """SELECT Title, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND Title <> '' GROUP BY Title ORDER BY PageViews DESC LIMIT 10"""

comptime _Q38 = """SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND IsLink <> 0 AND IsDownload = 0 GROUP BY URL ORDER BY PageViews DESC LIMIT 10 OFFSET 1000"""

comptime _Q39 = """SELECT TraficSourceID, SearchEngineID, AdvEngineID, CASE WHEN (SearchEngineID = 0 AND AdvEngineID = 0) THEN Referer ELSE '' END AS Src, URL AS Dst, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 GROUP BY TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst ORDER BY PageViews DESC LIMIT 10 OFFSET 1000"""

comptime _Q40 = """SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND TraficSourceID IN (-1, 6) AND RefererHash = 3594120000172545465 GROUP BY URLHash, EventDate ORDER BY PageViews DESC LIMIT 10 OFFSET 100"""

comptime _Q41 = """SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND DontCountHits = 0 AND URLHash = 2868770270353813622 GROUP BY WindowClientWidth, WindowClientHeight ORDER BY PageViews DESC LIMIT 10 OFFSET 10000"""

comptime _Q42 = """SELECT DATE_TRUNC('minute', EventTime) AS M, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-14' AND EventDate <= '2013-07-15' AND IsRefresh = 0 AND DontCountHits = 0 GROUP BY DATE_TRUNC('minute', EventTime) ORDER BY DATE_TRUNC('minute', EventTime) LIMIT 10 OFFSET 1000"""


def _q(query_id: String, text: String) -> Query:
    return Query(
        String(SUITE_CLICKBENCH),
        query_id.copy(),
        String(DATASET_CLICKBENCH),
        text.copy(),
    )


def clickbench_suite() -> Suite:
    var qs = List[Query]()
    qs.append(_q("q0", _Q0))
    qs.append(_q("q1", _Q1))
    qs.append(_q("q2", _Q2))
    qs.append(_q("q3", _Q3))
    qs.append(_q("q4", _Q4))
    qs.append(_q("q5", _Q5))
    qs.append(_q("q6", _Q6))
    qs.append(_q("q7", _Q7))
    qs.append(_q("q8", _Q8))
    qs.append(_q("q9", _Q9))
    qs.append(_q("q10", _Q10))
    qs.append(_q("q11", _Q11))
    qs.append(_q("q12", _Q12))
    qs.append(_q("q13", _Q13))
    qs.append(_q("q14", _Q14))
    qs.append(_q("q15", _Q15))
    qs.append(_q("q16", _Q16))
    qs.append(_q("q17", _Q17))
    qs.append(_q("q18", _Q18))
    qs.append(_q("q19", _Q19))
    qs.append(_q("q20", _Q20))
    qs.append(_q("q21", _Q21))
    qs.append(_q("q22", _Q22))
    qs.append(_q("q23", _Q23))
    qs.append(_q("q24", _Q24))
    qs.append(_q("q25", _Q25))
    qs.append(_q("q26", _Q26))
    qs.append(_q("q27", _Q27))
    qs.append(_q("q28", _Q28))
    qs.append(_q("q29", _Q29))
    qs.append(_q("q30", _Q30))
    qs.append(_q("q31", _Q31))
    qs.append(_q("q32", _Q32))
    qs.append(_q("q33", _Q33))
    qs.append(_q("q34", _Q34))
    qs.append(_q("q35", _Q35))
    qs.append(_q("q36", _Q36))
    qs.append(_q("q37", _Q37))
    qs.append(_q("q38", _Q38))
    qs.append(_q("q39", _Q39))
    qs.append(_q("q40", _Q40))
    qs.append(_q("q41", _Q41))
    qs.append(_q("q42", _Q42))
    return Suite(
        String(SUITE_CLICKBENCH),
        String("ClickBench, 43 queries over the hits table"),
        String(""),
        qs^,
    )
