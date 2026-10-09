"""Row functions the runtime tests call to look at the runtime from inside
the interpreter a call runs in: its isolation settings and sys.path, its
allocated blocks, rows and views kept past their batch, and what a row
object allows. Each returns a number the test compares.
"""

import gc
import os
import sys
import threading

# keeps_view: the row of batch 1, and the RowExpired its later batch kept.
KEPT_VIEW = []
SAVED = []
# keeps_raised: the row of batch 1, and the RowExpired that escaped later.
KEPT_RAISED = []
SAVED_RAISED = []


def pyrt_first(row) -> int:
    """1 when this module's directory is sys.path[0]."""
    return 1 if os.path.abspath(sys.path[0]) == os.path.dirname(os.path.abspath(__file__)) else 0


def site_free(row) -> int:
    """1 when the interpreter imported no site module."""
    return 0 if "site" in sys.modules else 1


def forks(row) -> int:
    """0 when this interpreter refuses fork; 1 when a child was forked."""
    try:
        pid = os.fork()
    except RuntimeError:
        return 0
    if pid == 0:
        os._exit(0)
    os.waitpid(pid, 0)
    return 1


def execs(row) -> int:
    """0 when this interpreter refuses exec; 1 when exec was tried (and
    failed: the path does not exist)."""
    try:
        os.execv("/nonexistent/komira-udf-check", ["komira-udf-check"])
    except RuntimeError:
        return 0
    except OSError:
        return 1
    return 2


def _start(daemon):
    try:
        t = threading.Thread(target=lambda: None, daemon=daemon)
        t.start()
        t.join()
    except RuntimeError:
        return 0
    return 1


def threads(row) -> int:
    """1 when a thread starts and joins in this interpreter, else 0."""
    return _start(False)


def daemon_threads(row) -> int:
    """1 when a daemon thread starts in this interpreter, else 0."""
    return _start(True)


def blocks(row) -> int:
    """The memory blocks this interpreter has allocated, after a collection
    (row types and instances hold reference cycles)."""
    gc.collect()
    return sys.getallocatedblocks()


def _write_through(e):
    """Writes through the column view held by the innermost frame of e's
    traceback (the adapter's field read, local `c`): 2.0 when refused, 3.0
    when it went through. A function of its own, so that no frame in e's
    traceback refers back to the traceback."""
    tb = e.__traceback__
    while tb.tb_next is not None:
        tb = tb.tb_next
    view = tb.tb_frame.f_locals["c"][0]
    try:
        view[0] = 0.0
    except TypeError:
        return 2.0
    return 3.0


def instances(row) -> int:
    """After a collection, 1000 x the RowInstance objects alive in this
    interpreter + the lists equal to ["price", "qty"] (a read set the C side
    passed to open_instance)."""
    gc.collect()
    n = 0
    for o in gc.get_objects():
        if type(o).__name__ == "RowInstance":
            n += 1000
        elif type(o) is list and o == ["price", "qty"]:
            n += 1
    return n


def _views_released(e):
    """Whether every view the adapter's call made, and the runtime's own
    views it was given, are released, as found in the frame of
    RowInstance.call that e's frames lead back to (each frame keeps its
    caller's frame)."""
    tb = e.__traceback__
    while tb.tb_next is not None:
        tb = tb.tb_next
    f = tb.tb_frame
    while f is not None and "cancel" not in f.f_locals:
        f = f.f_back
    if f is None:
        return False
    for name in ("o", "flag", "out", "outv", "cancel"):
        try:
            f.f_locals[name].nbytes
        except ValueError:
            continue  # released
        return False
    return True


def keeps_view(row) -> float:
    """Batch 1 keeps its row (1.0). Batch 2 reads it, catches the
    RowExpired and keeps it, its frames holding batch 2's column view, and
    writes through that view (_write_through). Batch 3 checks that the views
    of batch 2's call kept by those frames are released, then drops the
    exception and collects (4.0; 5.0 when a view was still live)."""
    if not KEPT_VIEW:
        KEPT_VIEW.append(row)
        return 1.0
    if SAVED:
        released = _views_released(SAVED[0])
        SAVED.clear()
        gc.collect()
        return 4.0 if released else 5.0
    try:
        return KEPT_VIEW[0].price
    except RuntimeError as e:
        SAVED.append(e)
        return _write_through(e)


def keeps_raised(row) -> float:
    """Batch 1 keeps its row; batch 2 reads it and lets the RowExpired
    escape, keeping a reference to it first."""
    if not KEPT_RAISED:
        KEPT_RAISED.append(row)
        return 1.0
    try:
        return KEPT_RAISED[0].price
    except RuntimeError as e:
        SAVED_RAISED.append(e)
        raise


def writes_cancel(row) -> int:
    """Finds the cancel flag's view in the adapter's frames up the stack and
    writes it: 0 when refused, 1 when it went through (the next row would
    then see a cancel the host never asked for)."""
    f = sys._getframe()
    while f is not None and "cancel" not in f.f_locals:
        f = f.f_back
    try:
        f.f_locals["cancel"][0] = 0
    except TypeError:
        return 0
    return 1


class _BadFloat:
    def __float__(self):
        raise RuntimeError("no float")


def bad_float(row) -> float:
    """Returns an object whose conversion to float raises."""
    return _BadFloat()


def raises_spaced(row) -> float:
    """Raises with a message spread over lines, tabs and runs of spaces."""
    raise ValueError("  a\n\tb\r\n  c  ")


def huge_int(row) -> int:
    """An int too large for int64."""
    return 2**70


def huge_float(row) -> float:
    """An int too large for float64."""
    return 10**400


def const_one(row) -> float:
    """Reads no field: its read set is empty."""
    return 1.0


def dunder_probe(row) -> float:
    """Probes a dunder the language looks up: not a field read."""
    return row.price if getattr(row, "__length_hint__", None) is None else -1.0


def under_x(row) -> float:
    """Reads `__x` with a default: a field read outside the read set."""
    return getattr(row, "__x", -1.0)


def x_under(row) -> float:
    """Reads `x__` with a default: a field read outside the read set."""
    return getattr(row, "x__", -1.0)


def odd_names(row) -> float:
    """Fields with no attribute fast path, read by attribute: one starting
    with "_", one that is not an identifier."""
    return row._hidden + getattr(row, "with space")


def reserved(row) -> float:
    """A field named like the row's own slot, read by subscript."""
    return row["_i"]


def assigns(row) -> float:
    """How many of two assignments the row refuses: to a field, to a new
    name."""
    n = 0.0
    for name in ("price", "extra"):
        try:
            setattr(row, name, 1.0)
        except AttributeError:
            n += 1.0
    return n


def iterates(row) -> float:
    """Iterates the row."""
    return float(len(list(row)))


def reprs(row) -> float:
    """1.0 when the row's repr and type name are the runtime's."""
    return 1.0 if repr(row) == "Row(price=7.0)" and type(row).__name__ == "Row" else 0.0
