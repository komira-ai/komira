# =============================================================================
# spill_root -- a fresh, uniquely named spill directory for one aggregate or
# sort
# =============================================================================

from std.ffi import external_call
from std.os import makedirs, mkdir
from std.os.path import exists

from komira_counters.global_counter import GlobalCounter


comptime _SPILL_ROOT_TRIES: Int = 64
"""Names tried for the spill root before `create_spill_root` gives up."""

comptime _SPILL_ROOT_COUNTER = GlobalCounter["komira_op_spill_rows_root"]


def create_spill_root(spill_dir: String, kind: String) raises -> String:
    """Create, and return the path of, a new sub-directory of `spill_dir`
    named `thsplc_<kind>_<pid>_<counter>` (the counter is process-wide).

    The directory is created exclusively: a name that already exists (a stale
    directory, another spill state, another process sharing `spill_dir`) is
    never reused; the next counter value is tried, up to 64 times, and then
    this raises naming `spill_dir`. `spill_dir` itself is created if missing.
    """
    makedirs(spill_dir, exist_ok=True)
    var pid = Int(external_call["getpid", Int32]())
    for _ in range(_SPILL_ROOT_TRIES):
        _SPILL_ROOT_COUNTER.incr()
        var root = (
            spill_dir
            + "/thsplc_"
            + kind
            + "_"
            + String(pid)
            + "_"
            + String(_SPILL_ROOT_COUNTER.read())
        )
        try:
            mkdir(root, 0o755)
            return root^
        except e:
            # An existing name is a collision (retry); any other failure
            # (permissions, a read-only parent) is the caller's to see.
            if not exists(root):
                raise Error(
                    "cannot create a spill directory under '"
                    + spill_dir
                    + "': "
                    + String(e)
                )
    raise Error(
        "no free spill directory name under '"
        + spill_dir
        + "' after "
        + String(_SPILL_ROOT_TRIES)
        + " tries"
    )
