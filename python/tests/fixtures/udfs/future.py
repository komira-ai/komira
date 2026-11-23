"""Fixtures whose annotations are strings (`from __future__ import annotations`)."""

from __future__ import annotations

import dataclasses
from typing import Optional, TypedDict

from komira._capture import udf


class Pair(TypedDict):
    a: int
    b: int


@dataclasses.dataclass
class Point:
    x: int
    y: int


@udf
def scalar(x: int) -> int:
    return x


@udf
def optional(x: int) -> Optional[float]:
    return None


@udf
def piped(x: int) -> int | None:
    return None


@udf(kind="row")
def typed_row(r: Pair) -> int:
    return r["a"]


@udf(kind="row")
def dataclass_row(r: Point) -> float:
    return r.x


@udf(kind="row")
def scanned(r: dict) -> int:
    return r.p + r["q"]
