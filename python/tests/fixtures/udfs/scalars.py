"""Scalar, column and module-shape fixtures."""

from typing import Any, Optional

from komira._capture import udf


@udf
def double(x: int) -> int:
    """Twice x."""
    return x * 2


@udf
def halve(x: float) -> float:
    return x / 2


@udf
def maybe(x: int) -> Optional[int]:
    return None if x < 0 else x


@udf
def maybe_pipe(x: float) -> float | None:
    return None if x < 0 else x


@udf(return_dtype="int32")
def narrow(x):
    return x


@udf(return_dtype="float64", stability="immutable", null_mode="manual")
def declared(x):
    return x


@udf(kind="map_batches_column", return_dtype="int64", stability="volatile")
def batch(values):
    return values


@udf(kind="map_batches_column")
def batch_hinted(values) -> float:
    return values


@udf
def no_hint(x):
    return x


@udf
def hint_str(x) -> str:
    return str(x)


@udf
def hint_bool(x) -> bool:
    return bool(x)


@udf
def hint_union(x) -> int | float:
    return x


@udf
def hint_optional_union(x) -> Optional[int | float]:
    return x


@udf
def hint_any(x) -> Any:
    return x


@udf
def hint_list(x) -> list[int]:
    return [x]


@udf
def hint_none(x) -> None:
    return None


@udf(return_dtype="int64")
def declared_over_str(x) -> str:
    return x


@udf
def hint_unresolvable(x) -> "NoSuchName":  # noqa: F821
    return x


def plain(x: int) -> int:
    return x + 1


lam = lambda x: x  # noqa: E731
as_lambda = udf(return_dtype="int64")(lambda x: x)


def make_nested():
    def inner(x: int) -> int:
        return x

    return inner


NESTED = make_nested()


class Holder:
    def method(self, x: int) -> int:
        return x


METHOD = Holder.method


def replaced(x: int) -> int:
    return x


REPLACED = udf(replaced)
replaced = "another object"


class Callable_:
    def __call__(self, x):
        return x


INSTANCE = Callable_()
