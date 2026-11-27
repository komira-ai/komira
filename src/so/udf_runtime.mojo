"""The UDF runtime of a session, and the binding of a plan's UDFs on it.

`set_udf_runtime` is `komira_udf_runtime_set`: it opens the runtime library
the caller names (`udf_host.runtime.UdfRuntime`: dlopen, init with the
options, the table and `describe` checked) and makes it the session's,
replacing the one it held. The runtime is opened now, so a library that does
not load or an option the runtime refuses is refused by this call; a run
already holding the old runtime keeps it until it ends, and the old one is
shut down when the last holder drops it. The options are the runtime's own
`key=value` strings, one per line of the text, passed on unread; empty lines
are skipped.

`bind_udfs` is the plan door's admission of an envelope's UDF list
(`plan_result`, step `bind`): an empty list binds nothing; a list on a
session that holds no runtime is refused by name
(`OPTIMIZED_ENV_RUNTIME_MISSING`); otherwise every UDF is admitted, validated
and loaded on the session's runtime (`udf_host.runtime.UdfBinding.bind`)
before the plan runs.
"""

from std.memory import ArcPointer

from plan_ir.udf_ref import UdfRef
from udf_host.runtime import UdfBinding, UdfRuntime, UdfRuntimeConfig
from udf_host.status import OPTIMIZED_ENV_RUNTIME_MISSING

from .session import Session


def runtime_options(text: String) -> List[String]:
    """The non-empty lines of `text`, in order: the runtime's options."""
    var out = List[String]()
    var lines = text.split("\n")
    for i in range(len(lines)):
        if lines[i].byte_length() > 0:
            out.append(String(lines[i]))
    return out^


def set_udf_runtime(
    mut session: Session,
    var library: String,
    var code_root: String,
    batch_deadline_ms: Int,
    options_text: String,
) raises:
    """Open the runtime `library` with the options of `options_text` and make
    it `session`'s; its code objects are read from `code_root`, and a batch's
    call is bounded by `batch_deadline_ms` (0: the engine's default).

    Raises:
        `UDF_RUNTIME_CONFIG_INVALID` for a negative deadline or an empty
        library or code root; otherwise what `UdfRuntime.open` raises. The
        session keeps the runtime it held.
    """
    if batch_deadline_ms < 0 or library.byte_length() == 0 or code_root.byte_length() == 0:
        raise Error(
            "UDF_RUNTIME_CONFIG_INVALID: komira_udf_runtime_set needs a library, a code root and a"
            " deadline of 0 or more milliseconds"
        )
    var config = UdfRuntimeConfig(library^, runtime_options(options_text), code_root^, batch_deadline_ms)
    session.udf_runtime = Optional(ArcPointer(UdfRuntime.open(config^)))


def bind_udfs(ref session: Session, ref udfs: List[UdfRef]) raises -> ArcPointer[UdfBinding]:
    """The binding of a plan's UDF list on `session`'s runtime.

    Raises:
        `OPTIMIZED_ENV_RUNTIME_MISSING` when the list is not empty and the
        session holds no runtime; otherwise what `UdfBinding.bind` raises.
    """
    if len(udfs) == 0:
        return ArcPointer(UdfBinding())
    if not session.udf_runtime:
        raise Error(
            String(OPTIMIZED_ENV_RUNTIME_MISSING) + ": UDF 0 (" + udfs[0].code.entry + ", "
            + udfs[0].code.runtime + ") needs the runtime " + udfs[0].code.runtime
            + ", and this session holds no UDF runtime (komira_udf_runtime_set gives it one)"
        )
    return ArcPointer(UdfBinding.bind(session.udf_runtime.value(), udfs))
