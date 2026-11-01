# Lookup over the two suites and the three datasets.

from .datasets import (
    DATASET_H2O_GROUPBY,
    DATASET_H2O_JOIN,
    DATASET_TPCH,
    h2o_groupby_dataset,
    h2o_join_dataset,
    tpch_dataset,
)
from .h2o import SUITE_H2O, h2o_suite
from .query import Query, Suite
from .schema import Dataset
from .tpch import SUITE_TPCH, tpch_suite


def suite_ids() -> List[String]:
    """The ids of the suites, in the order of `suites()`: `tpch`,
    `h2o`."""
    var out = List[String]()
    out.append(String(SUITE_TPCH))
    out.append(String(SUITE_H2O))
    return out^


def suites() -> List[Suite]:
    """Every suite, in the order of `suite_ids()`."""
    var out = List[Suite]()
    out.append(tpch_suite())
    out.append(h2o_suite())
    return out^


def suite(suite_id: String) raises -> Suite:
    """The suite with that id; raises, naming the known ids, when there is
    none."""
    if suite_id == SUITE_TPCH:
        return tpch_suite()
    if suite_id == SUITE_H2O:
        return h2o_suite()
    raise Error(
        "komira_bench_corpus: no suite "
        + suite_id
        + " (one of: tpch, h2o)"
    )


def find_query(key: String) raises -> Query:
    """The query named `suite/id` (such as `tpch/q1` or `h2o/j3`); raises
    when the key has no slash, or the suite or the query does not exist."""
    var slash = key.find(String("/"))
    if slash < 0:
        raise Error(
            "komira_bench_corpus: query key " + key + " is not suite/id"
        )
    var found = suite(String(key[byte=:slash]))
    return found.query(String(key[byte = slash + 1 :]))


def dataset_names() -> List[String]:
    """The names of the datasets: `tpch`, `h2o_groupby`,
    `h2o_join`."""
    var out = List[String]()
    out.append(String(DATASET_TPCH))
    out.append(String(DATASET_H2O_GROUPBY))
    out.append(String(DATASET_H2O_JOIN))
    return out^


def dataset(name: String) raises -> Dataset:
    """The dataset with that name (the `dataset` of a `Query`); raises when
    there is none."""
    if name == DATASET_TPCH:
        return tpch_dataset()
    if name == DATASET_H2O_GROUPBY:
        return h2o_groupby_dataset()
    if name == DATASET_H2O_JOIN:
        return h2o_join_dataset()
    raise Error(
        "komira_bench_corpus: no dataset "
        + name
        + " (one of: tpch, h2o_groupby, h2o_join)"
    )
