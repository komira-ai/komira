# The 15 queries of the h2o database-like ops benchmark: groupby q1 to q10 over
# the table `x` of the groupby data, and join j1 to j5 over the tables of the
# join data (datasets.mojo), in the text of the benchmark's DuckDB script with
# the table name `x` in place of the per-run table names.
#
# The query text is taken from the h2o benchmark's `duckdb/groupby-duckdb.R` and
# `duckdb/join-duckdb.R`, published under the Mozilla Public License 2.0 (see
# README.md). This Source Code Form is subject to the terms of the Mozilla
# Public License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at the Mozilla Foundation's MPL 2.0 page.

from .datasets import DATASET_H2O_GROUPBY, DATASET_H2O_JOIN
from .query import Query, Suite

comptime SUITE_H2O = "h2o"

comptime _Q1 = """select id1, sum(v1) as v1 from x group by id1"""

comptime _Q2 = """select id1, id2, sum(v1) as v1 from x group by id1, id2"""

comptime _Q3 = """select id3, sum(v1) as v1, avg(v3) as v3 from x group by id3"""

comptime _Q4 = """select id4, avg(v1) as v1, avg(v2) as v2, avg(v3) as v3 from x group by id4"""

comptime _Q5 = """select id6, sum(v1) as v1, sum(v2) as v2, sum(v3) as v3 from x group by id6"""

comptime _Q6 = """select id4, id5, median(v3) as median_v3, stddev(v3) as sd_v3 from x group by id4, id5"""

comptime _Q7 = """select id3, max(v1) - min(v2) as range_v1_v2 from x group by id3"""

comptime _Q8 = """select id6, v3 as largest2_v3
from (
  select id6, v3, row_number() over (partition by id6 order by v3 desc) as order_v3
  from x
  where v3 is not null
) as sub_query
where order_v3 <= 2"""

comptime _Q9 = """select id2, id4, pow(corr(v1, v2), 2) as r2 from x group by id2, id4"""

comptime _Q10 = """select id1, id2, id3, id4, id5, id6, sum(v3) as v3, count(*) as count from x group by id1, id2, id3, id4, id5, id6"""

comptime _J1 = """select x.*, small.id4 as small_id4, v2 from x inner join small using (id1)"""

comptime _J2 = """select x.*, medium.id1 as medium_id1, medium.id4 as medium_id4, medium.id5 as medium_id5, v2 from x inner join medium using (id2)"""

comptime _J3 = """select x.*, medium.id1 as medium_id1, medium.id4 as medium_id4, medium.id5 as medium_id5, v2 from x left join medium using (id2)"""

comptime _J4 = """select x.*, medium.id1 as medium_id1, medium.id2 as medium_id2, medium.id4 as medium_id4, v2 from x inner join medium using (id5)"""

comptime _J5 = """select x.*, big.id1 as big_id1, big.id2 as big_id2, big.id4 as big_id4, big.id5 as big_id5, big.id6 as big_id6, v2 from x inner join big using (id3)"""


def _g(query_id: String, text: String) -> Query:
    return Query(
        String(SUITE_H2O),
        query_id.copy(),
        String(DATASET_H2O_GROUPBY),
        text.copy(),
    )


def _j(query_id: String, text: String) -> Query:
    return Query(
        String(SUITE_H2O),
        query_id.copy(),
        String(DATASET_H2O_JOIN),
        text.copy(),
    )


def h2o_suite() -> Suite:
    var qs = List[Query]()
    qs.append(_g("q1", _Q1))
    qs.append(_g("q2", _Q2))
    qs.append(_g("q3", _Q3))
    qs.append(_g("q4", _Q4))
    qs.append(_g("q5", _Q5))
    qs.append(_g("q6", _Q6))
    qs.append(_g("q7", _Q7))
    qs.append(_g("q8", _Q8))
    qs.append(_g("q9", _Q9))
    qs.append(_g("q10", _Q10))
    qs.append(_j("j1", _J1))
    qs.append(_j("j2", _J2))
    qs.append(_j("j3", _J3))
    qs.append(_j("j4", _J4))
    qs.append(_j("j5", _J5))
    return Suite(
        String(SUITE_H2O),
        String("h2o groupby q1-q10 and join j1-j5"),
        String(""),
        qs^,
    )
