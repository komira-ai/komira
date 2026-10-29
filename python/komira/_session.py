"""`Session`: one libkomira context, with Python values in and out."""

from __future__ import annotations

from typing import Optional

import pyarrow as pa

from . import _native
from ._native import KomiraError
from ._wire import schema_from_wire


class Session:
    """A context handle of the library; closing it frees the handle once.

        with Session("/path/to/libkomira.so") as s:
            s.register_parquet("t", "/data/t.parquet")
            schema = s.parquet_schema("/data/t.parquet")

    A session is not safe to use from two threads at once (the handle's contract).
    """

    def __init__(self, lib_path: Optional[str] = None):
        self._native = _native.load(lib_path)
        self._ctx = self._native.ctx_new()

    def close(self) -> None:
        ctx, self._ctx = self._ctx, None
        if ctx:
            self._native.ctx_free(ctx)

    def __enter__(self) -> "Session":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:  # noqa: BLE001 - a finalizer at interpreter exit must not raise
            pass

    def _live(self):
        if not self._ctx:
            raise KomiraError("the session is closed")
        return self._ctx

    def register_parquet(self, name: str, path) -> None:
        """Bind the Parquet file at `path` under `name` (its footer is read now)."""
        self._native.register_parquet(self._live(), name, path)

    def parquet_schema(self, path) -> pa.Schema:
        """The Arrow schema of the Parquet file at `path`, read from its footer."""
        return schema_from_wire(self._native.parquet_schema(self._live(), path))

    def plan_render(self, plan: bytes) -> str:
        """The text of a serialized plan (a `WirePlanEnvelope`), as authored; it is not run."""
        return self._native.plan_render(self._live(), plan)
