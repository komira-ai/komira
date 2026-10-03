# =============================================================================
# src/kci_cli/recorder.mojo -- where the run's result document goes: the
#   file `--result-file` names, written temp-and-rename.
# =============================================================================
#
# `CliRecorder` is the one `RunRecorder` (kci_contract) the CLI hands every
# step: with no `--result-file` it records nothing; with one, every record
# (`begin`: RUNNING, `finish`: FINISHED) replaces the file whole, through
# `<path>.kci-tmp` and rename(2), so a reader never sees half a document. A
# file still at RUNNING means the run was stopped (a signal, out of memory),
# and kci_contract reads it as INTERRUPTED. `memory()` keeps every record in
# memory as well, for the welded tests.
#
# A record that cannot be written RAISES: before the first effect that stops
# the run (the steps treat a failing `begin` as FAILED with nothing done);
# at `finish` the CLI says so on stderr and keeps the exit number.
#
# FFI-BOUNDARY: `_rename` is the one external call (rename(2), fixed arity);
# the path Strings are held by locals across the call, and no pointer leaves
# it.
#
# Encapsulation: owned values; no pointer crosses this module, no wildcard
# origin.
# =============================================================================

from std.ffi import external_call
from std.os import remove
from std.os.path import exists
from std.pathlib import Path

from kci_contract import RunRecorder, RunResult, render_result

comptime TMP_SUFFIX: String = ".kci-tmp"


def _rename(src: String, dst: String) raises:
    var s = src
    var d = dst
    # SAFETY: `s` and `d` are locals that hold both NUL-terminated paths alive
    # across this synchronous call; the kernel copies the bytes and the
    # pointers never escape. rename(2) is fixed-arity.
    var rc = external_call["rename", Int32](
        s.as_c_string_slice().unsafe_ptr(),
        d.as_c_string_slice().unsafe_ptr(),
    )
    if rc != 0:
        raise Error(String("rename ") + src + String(" -> ") + dst + String(" failed"))


def write_whole_file(path: String, text: String) raises:
    """Replace `path` by `text`: write `<path>.kci-tmp`, then rename it."""
    var tmp = path + String(TMP_SUFFIX)
    Path(tmp).write_text(text)
    try:
        _rename(tmp, path)
    except e:
        if exists(tmp):
            remove(tmp)
        raise Error(String(e))


struct CliRecorder(RunRecorder, Movable):
    """The run's recorder (file header).

    Layout: owned values only. No pointer field."""

    var path: String
    var keep: Bool
    var records: List[String]
    var statuses: List[String]

    def __init__(out self, var path: String):
        """Records to `path`; "" records nothing."""
        self.path = path^
        self.keep = False
        self.records = List[String]()
        self.statuses = List[String]()

    @staticmethod
    def memory(var path: String) -> CliRecorder:
        """As `CliRecorder(path)`, and every record kept in memory too."""
        var r = CliRecorder(path^)
        r.keep = True
        return r^

    def _record(mut self, r: RunResult) raises:
        var text = render_result(r)
        if self.keep:
            self.records.append(text.copy())
            self.statuses.append(r.status.copy())
        if self.path.byte_length() > 0:
            write_whole_file(self.path, text)

    def begin(mut self, r: RunResult) raises:
        self._record(r)

    def finish(mut self, r: RunResult) raises:
        self._record(r)
