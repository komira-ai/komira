"""A module that parses and refuses to import."""


def f(row) -> float:
    return row.price


raise RuntimeError("refused at import")
