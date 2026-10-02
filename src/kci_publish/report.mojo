# =============================================================================
# src/kci_publish/report.mojo -- contract step 6: one JSON report per run
#   (`--report`), and the lines printed beside it.
# =============================================================================
#
#   {"channel": .., "dry_run": bool, "exit_code": n,
#    "files": [{"action": .., "file": "<subdir>/<file>", "indexed": bool,
#               "name": .., "sha256": .., "state_after": ..,
#               "state_before": ..}, ...in upload order],
#    "release_commit": .., "set_hash": .., "verdict": ..}
#
# Keys sorted, compact, one trailing newline. ⛔ NO SECRET: nothing a
# credential produced is placed in the report or the lines -- only file
# names, digests, states and the channel's answers, which kci_pkg_upload has
# already passed through its credential-echo redaction.
#
# THE EXIT CODES (one table; the release job treats {0, 6} as green):
#   0 PUBLISHED           every member and the metapackage present and read back
#   2 USAGE
#   3 REFUSED             step 0: the set, lockstep, closure, set hash
#   4 FAILED              an upload answered definitively, not as success
#   5 CANNOT_TELL         a read could not be answered
#   6 ALREADY_PUBLISHED   every file present and identical; nothing uploaded
#   7 STOP_DIFFERENT_BYTES same file name, other sha256
#   8 STOP_NEW_NAME       an unclaimed new name, or a claim that is not new
#   9 PARTIAL             members still absent after the bounded retries
#  10 READ_BACK_MISMATCH
# In 4, 5 (after step 1), 7 (after step 1), 9 and 10 some members may have
# been uploaded and the metapackage never was.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_json import JsonValue

from .plan import STATE_NOT_READ, PublishTarget, state_name


comptime EXIT_PUBLISHED: Int = 0
comptime EXIT_USAGE: Int = 2
comptime EXIT_REFUSED: Int = 3
comptime EXIT_FAILED: Int = 4
comptime EXIT_CANNOT_TELL: Int = 5
comptime EXIT_ALREADY_PUBLISHED: Int = 6
comptime EXIT_STOP_DIFFERENT_BYTES: Int = 7
comptime EXIT_STOP_NEW_NAME: Int = 8
comptime EXIT_PARTIAL: Int = 9
comptime EXIT_READ_BACK_MISMATCH: Int = 10


def verdict_name(code: Int) -> String:
    if code == EXIT_PUBLISHED:
        return String("PUBLISHED")
    if code == EXIT_USAGE:
        return String("USAGE")
    if code == EXIT_REFUSED:
        return String("REFUSED")
    if code == EXIT_FAILED:
        return String("FAILED")
    if code == EXIT_CANNOT_TELL:
        return String("CANNOT_TELL")
    if code == EXIT_ALREADY_PUBLISHED:
        return String("ALREADY_PUBLISHED")
    if code == EXIT_STOP_DIFFERENT_BYTES:
        return String("STOP_DIFFERENT_BYTES")
    if code == EXIT_STOP_NEW_NAME:
        return String("STOP_NEW_NAME")
    if code == EXIT_PARTIAL:
        return String("PARTIAL")
    if code == EXIT_READ_BACK_MISMATCH:
        return String("READ_BACK_MISMATCH")
    return String("EXIT(") + String(code) + String(")")


struct FileRow(Copyable, Movable):
    """One file's row of the report. Layout: owned values. No pointer."""

    var name: String
    var file: String
    var sha256_hex: String
    var state_before: Int
    var action: String
    var state_after: Int
    var indexed: Bool

    def __init__(out self, t: PublishTarget):
        self.name = t.coordinate.distribution.copy()
        self.file = t.where()
        self.sha256_hex = t.sha256_hex.copy()
        self.state_before = STATE_NOT_READ
        self.action = String("none")
        self.state_after = STATE_NOT_READ
        self.indexed = False


struct PublishReport(Copyable, Movable):
    """The run's outcome. Layout: owned values only. No pointer field."""

    var exit_code: Int
    var channel: String
    var dry_run: Bool
    var set_hash: String
    var release_commit: String
    var files: List[FileRow]
    var lines: List[String]

    def __init__(out self):
        self.exit_code = EXIT_PUBLISHED
        self.channel = String("")
        self.dry_run = False
        self.set_hash = String("")
        self.release_commit = String("")
        self.files = List[FileRow]()
        self.lines = List[String]()

    @staticmethod
    def refused(code: Int, var message: String) -> PublishReport:
        """A report for a run stopped before step 1: `message`'s lines and
        `code`."""
        var r = PublishReport()
        r.exit_code = code
        var parts = message.split(String("\n"))
        for i in range(len(parts)):
            r.lines.append(String(parts[i]))
        return r^

    def has_line_containing(self, needle: String) -> Bool:
        for i in range(len(self.lines)):
            if self.lines[i].find(needle) >= 0:
                return True
        return False

    def finish_line(mut self):
        self.lines.append(
            String("RESULT exit=")
            + String(self.exit_code)
            + String(" verdict=")
            + verdict_name(self.exit_code)
            + String(" set_hash=")
            + self.set_hash
        )


def render_report(r: PublishReport) raises -> String:
    """The report JSON (see the file header)."""
    var files = JsonValue.empty_array()
    for i in range(len(r.files)):
        ref f = r.files[i]
        var row = JsonValue.empty_object()
        row.set_member(String("action"), JsonValue.from_string(f.action.copy()))
        row.set_member(String("file"), JsonValue.from_string(f.file.copy()))
        row.set_member(String("indexed"), JsonValue.from_bool(f.indexed))
        row.set_member(String("name"), JsonValue.from_string(f.name.copy()))
        row.set_member(String("sha256"), JsonValue.from_string(f.sha256_hex.copy()))
        row.set_member(String("state_after"), JsonValue.from_string(state_name(f.state_after)))
        row.set_member(String("state_before"), JsonValue.from_string(state_name(f.state_before)))
        files.push(row^)
    var doc = JsonValue.empty_object()
    doc.set_member(String("channel"), JsonValue.from_string(r.channel.copy()))
    doc.set_member(String("dry_run"), JsonValue.from_bool(r.dry_run))
    doc.set_member(String("exit_code"), JsonValue.from_number(String(r.exit_code)))
    doc.set_member(String("files"), files^)
    doc.set_member(String("release_commit"), JsonValue.from_string(r.release_commit.copy()))
    doc.set_member(String("set_hash"), JsonValue.from_string(r.set_hash.copy()))
    doc.set_member(String("verdict"), JsonValue.from_string(verdict_name(r.exit_code)))
    return doc.serialize() + String("\n")


def write_report(r: PublishReport, path: String) raises:
    Path(path).write_text(render_report(r))
