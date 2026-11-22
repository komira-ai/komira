# The ORDER BY keys of the TPC-H corpus queries, as zero-based positions over
# each query's result columns (the select list in src/bench_corpus/tpch.mojo).
# A recorded answer carries them so that a consumer can check the order of the
# rows an engine returns as well as their values.

from bench_duckdb import OrderKey


def _asc(column: Int) -> OrderKey:
    return OrderKey(column, False, False)


def _desc(column: Int) -> OrderKey:
    return OrderKey(column, True, False)


def tpch_order_keys(id: String) raises -> List[OrderKey]:
    """The keys of the top-level ORDER BY of TPC-H query `id` (`q1` .. `q22`),
    empty for a query that has none (q6, q14, q17, q19).

    Raises:
        Error: an id that is not one of the 22 queries.
    """
    var k = List[OrderKey]()
    if id == "q1":
        k.append(_asc(0))
        k.append(_asc(1))
    elif id == "q2":
        k.append(_desc(0))
        k.append(_asc(2))
        k.append(_asc(1))
        k.append(_asc(3))
    elif id == "q3":
        k.append(_desc(1))
        k.append(_asc(2))
    elif id == "q4" or id == "q8" or id == "q12" or id == "q15" or id == "q20" or id == "q22":
        k.append(_asc(0))
    elif id == "q5" or id == "q10" or id == "q11":
        # q5 and q11 order by their second column; q10 by its third.
        k.append(_desc(2 if id == "q10" else 1))
    elif id == "q7":
        k.append(_asc(0))
        k.append(_asc(1))
        k.append(_asc(2))
    elif id == "q9":
        k.append(_asc(0))
        k.append(_desc(1))
    elif id == "q13":
        k.append(_desc(1))
        k.append(_desc(0))
    elif id == "q16":
        k.append(_desc(3))
        k.append(_asc(0))
        k.append(_asc(1))
        k.append(_asc(2))
    elif id == "q18":
        k.append(_desc(4))
        k.append(_asc(3))
    elif id == "q21":
        k.append(_desc(1))
        k.append(_asc(0))
    elif id == "q6" or id == "q14" or id == "q17" or id == "q19":
        pass
    else:
        raise Error(String("no TPC-H query is called '") + id + String("'"))
    return k^
