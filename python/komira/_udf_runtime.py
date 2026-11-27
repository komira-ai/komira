"""The UDF runtime of one session: a plan that carries Python UDFs
(`WirePlanEnvelope.udfs`) runs through the komira/python runtime library of
the wheel (`libkomira_udf_python.so` in `komira/_lib/`), which libkomira opens
by path (`komira_udf_runtime_set`, ABI 1.11).

`UdfRuntime` is a session's private scratch tree (`code/`, the code root, and
`rt/`, the runtime's scratch) and the one-time `komira_udf_runtime_set`.
`prepare` runs before each plan call: on the first plan with UDFs it sets the
runtime, and for each UdfRef it writes the code objects the process captured
under the code root. A runtime library the package does not carry (macOS) is
not set, so the engine refuses the plan by name; so is a code object this
process never captured.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import sys
import sysconfig
import tempfile

from . import _native
from ._capture import _code

_RUNTIME_FILE = "libkomira_udf_python.dylib" if sys.platform == "darwin" else "libkomira_udf_python.so"


def _options(scratch: str) -> list[str]:
    """The runtime's `key=value` options: this interpreter, the installed
    zygote, the interpreter's ABI tag, the scratch directory and every
    existing non-stdlib directory of `sys.path`."""
    spec = importlib.util.find_spec("komira._udf.zygote")
    std = {os.path.realpath(sysconfig.get_path(k)) for k in ("stdlib", "platstdlib")}
    skip = std | {os.path.join(p, "lib-dynload") for p in std}
    options = [
        "interpreter=" + sys.executable,
        "zygote=" + str(spec.origin),
        "abi=cp" + sys.implementation.cache_tag.replace("cpython-", ""),
        "scratch=" + scratch,
    ]
    options.extend("sys_path=" + p for p in sys.path if p and os.path.isdir(p) and os.path.realpath(p) not in skip)
    return options


class UdfRuntime:
    def __init__(self) -> None:
        self._root: str | None = None
        self._set = False

    @property
    def root(self) -> str | None:
        """The scratch tree, None before the first plan with UDFs."""
        return self._root

    def prepare(self, native: _native.Native, ctx: int, plan: bytes) -> None:
        """Gets the session ready to run `plan`: nothing when its envelope
        names no UDF."""
        from .plan.v1 import plan_pb2

        envelope = plan_pb2.WirePlanEnvelope()
        envelope.ParseFromString(plan)
        if not envelope.udfs:
            return
        if self._root is None:
            self._root = tempfile.mkdtemp(prefix="komira-udf-")
            os.mkdir(os.path.join(self._root, "code"))
            os.mkdir(os.path.join(self._root, "rt"))
        code_root = os.path.join(self._root, "code")
        if not self._set:
            library = os.path.join(_native._loaded_dir or _native._PACKAGE_LIB_DIR, _RUNTIME_FILE)
            if os.path.isfile(library):
                native.udf_runtime_set(ctx, library, code_root, 0, _options(os.path.join(self._root, "rt")))
                self._set = True
        for ref in envelope.udfs:
            for code in ref.code.code:
                data = _code.registered_object(bytes(code.sha256))
                if data is not None:
                    _code.write_objects(code_root, {bytes(code.sha256): data})

    def free(self, native: _native.Native, ctx: int) -> None:
        """Frees the context (which shuts the runtime down), then removes
        the scratch tree."""
        try:
            native.ctx_free(ctx)
        finally:
            self.remove()

    def remove(self) -> None:
        """Removes the scratch tree; the context is freed first."""
        root, self._root = self._root, None
        if root is not None:
            shutil.rmtree(root, ignore_errors=True)
