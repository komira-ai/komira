# The lock file: which dataset fingerprint a run used. A lock records, for one
# dataset at one scale, every file's observed size and sha256 and the manifest's
# row count, and ends with a fingerprint: the sha256 of every line before it. A
# result that names the fingerprint names exactly those bytes.
#
# The text is line based, fixed order, one space between words, a newline after
# every line (the last one too):
#
#   komira-bench-data-lock/1
#   dataset <name>
#   scale <scale>
#   generator <version, or - for supplied files>
#   file <path> <bytes> <sha256> <rows, or - when unrecorded>
#   ...
#   fingerprint <sha256 of the lines above>
#
# `decode_lock` is strict: a missing or extra line, a changed word, a bad number
# or checksum, a repeated path, or a fingerprint that does not match is an error.

from std.os.path import exists
from std.pathlib import Path

from komira_crypto import sha256, hex_lower_array_32

from .manifest import (
    DatasetManifest,
    UNRECORDED_ROWS,
    is_sha256_hex,
    is_token,
    validate_relative_path,
)
from .verify import FILE_UNRECORDED, FILE_VERIFIED, VerifyReport, file_status_name

comptime LOCK_FORMAT: String = "komira-bench-data-lock/1"
comptime LOCK_FILE_NAME: String = "data.lock"
"""The lock's name inside a cache directory."""


struct LockEntry(Copyable, Movable):
    var path: String
    var bytes: Int
    var sha256: String
    var rows: Int
    """The row count, or `UNRECORDED_ROWS`."""

    def __init__(out self, var path: String, bytes: Int, var sha256: String, rows: Int):
        self.path = path^
        self.bytes = bytes
        self.sha256 = sha256^
        self.rows = rows


struct DatasetLock(Copyable, Movable):
    """The files of one dataset as a run saw them."""

    var dataset: String
    var scale: String
    var generator: String
    """The generator's version token, or empty."""
    var entries: List[LockEntry]

    def __init__(
        out self,
        var dataset: String,
        var scale: String,
        var generator: String,
        var entries: List[LockEntry],
    ):
        self.dataset = dataset^
        self.scale = scale^
        self.generator = generator^
        self.entries = entries^

    def body(self) -> String:
        """Every line of the lock text except the fingerprint line."""
        var out = String(LOCK_FORMAT) + "\n"
        out += String("dataset ") + self.dataset + "\n"
        out += String("scale ") + self.scale + "\n"
        var gen = self.generator.copy() if self.generator.byte_length() > 0 else String("-")
        out += String("generator ") + gen + "\n"
        for i in range(len(self.entries)):
            ref e = self.entries[i]
            var rows = String(e.rows) if e.rows >= 0 else String("-")
            out += String("file ") + e.path + " " + String(e.bytes) + " " + e.sha256 + " " + rows + "\n"
        return out^

    def fingerprint(self) -> String:
        """The sha256 of `body()` as 64 lowercase hex characters."""
        var text = self.body()
        return hex_lower_array_32(sha256(text.as_bytes()))


def lock_from_report(manifest: DatasetManifest, report: VerifyReport) raises -> DatasetLock:
    """The lock for what `report` observed of `manifest`'s files.

    Raises:
        Error: the report is for another dataset or scale or another file
            list, or any file is not usable (missing, wrong size, wrong sha256):
            a lock is never written for files that fail.
    """
    manifest.validate()
    if report.dataset != manifest.name or report.scale != manifest.scale:
        raise Error(
            "lock: the report is for " + report.dataset + "/" + report.scale
            + ", not " + manifest.name + "/" + manifest.scale
        )
    if len(report.checks) != len(manifest.files):
        raise Error("lock: the report has " + String(len(report.checks)) + " files, the manifest " + String(len(manifest.files)))
    var entries = List[LockEntry]()
    for i in range(len(manifest.files)):
        ref f = manifest.files[i]
        ref c = report.checks[i]
        if c.path != f.path:
            raise Error("lock: the report lists " + c.path + " where the manifest lists " + f.path)
        if c.status != FILE_VERIFIED and c.status != FILE_UNRECORDED:
            raise Error("lock: " + f.path + " is " + file_status_name(c.status))
        entries.append(LockEntry(f.path.copy(), c.observed_bytes, c.observed_sha256.copy(), f.expected_rows))
    return DatasetLock(
        manifest.name.copy(), manifest.scale.copy(), manifest.generator.copy(), entries^
    )


def encode_lock(lock: DatasetLock) -> String:
    """The lock's text, ending in its fingerprint line."""
    return lock.body() + "fingerprint " + lock.fingerprint() + "\n"


def _parse_count(text: String, what: String) raises -> Int:
    """A non-negative decimal without sign, spaces or leading zeros."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n == 0 or n > 18:
        raise Error("lock: bad " + what + ": '" + text + "'")
    for i in range(n):
        if bytes[i] < 0x30 or bytes[i] > 0x39:
            raise Error("lock: bad " + what + ": '" + text + "'")
    if n > 1 and bytes[0] == 0x30:
        raise Error("lock: bad " + what + ": '" + text + "'")
    return atol(text)


def _words(line: String, head: String, count: Int) raises -> List[String]:
    var parts = line.split(" ")
    if len(parts) != count or String(parts[0]) != head:
        raise Error("lock: expected a '" + head + "' line of " + String(count) + " words, got '" + line + "'")
    var out = List[String]()
    for i in range(count):
        out.append(String(parts[i]))
    return out^


def decode_lock(text: String) raises -> DatasetLock:
    """Parse lock text and check its fingerprint.

    Raises:
        Error: naming the first line that is wrong, or a fingerprint that does
            not match the lines above it.
    """
    var lines = text.split("\n")
    var n = len(lines)
    if n < 6 or String(lines[n - 1]) != "":
        raise Error("lock: truncated (every line, the last too, ends in a newline)")
    if String(lines[0]) != LOCK_FORMAT:
        raise Error("lock: unknown format '" + String(lines[0]) + "'")
    var dataset = _words(String(lines[1]), "dataset", 2)[1].copy()
    var scale = _words(String(lines[2]), "scale", 2)[1].copy()
    var generator = _words(String(lines[3]), "generator", 2)[1].copy()
    if not is_token(dataset) or not is_token(scale):
        raise Error("lock: dataset and scale must be tokens")
    if generator == "-":
        generator = String()
    elif not is_token(generator):
        raise Error("lock: generator must be a token or -")
    var entries = List[LockEntry]()
    var last = n - 2
    for i in range(4, last):
        var w = _words(String(lines[i]), "file", 5)
        validate_relative_path(w[1])
        for j in range(len(entries)):
            if entries[j].path == w[1]:
                raise Error("lock: path listed twice: " + w[1])
        if not is_sha256_hex(w[3]):
            raise Error("lock: sha256 is not 64 lowercase hex for " + w[1])
        var rows = UNRECORDED_ROWS
        if w[4] != "-":
            rows = _parse_count(w[4], "row count")
        entries.append(LockEntry(w[1].copy(), _parse_count(w[2], "size"), w[3].copy(), rows))
    if len(entries) == 0:
        raise Error("lock: no files")
    var fp = _words(String(lines[last]), "fingerprint", 2)[1].copy()
    var lock = DatasetLock(dataset^, scale^, generator^, entries^)
    if fp != lock.fingerprint():
        raise Error("lock: the fingerprint does not match the lines above it (edited or corrupt)")
    return lock^


def _lock_path(cache_dir: String) raises -> String:
    if cache_dir.byte_length() == 0:
        raise Error("lock: the cache directory is empty")
    if cache_dir.as_bytes()[cache_dir.byte_length() - 1] == 0x2F:
        return cache_dir + LOCK_FILE_NAME
    return cache_dir + "/" + LOCK_FILE_NAME


def write_lock_file(cache_dir: String, lock: DatasetLock) raises:
    """Write the lock to `<cache_dir>/data.lock`. An existing lock is never
    replaced.

    Raises:
        Error: a lock is already there, or the file cannot be written.
    """
    var path = _lock_path(cache_dir)
    if exists(path):
        raise Error("lock: " + path + " exists; it is never overwritten")
    Path(path).write_text(encode_lock(lock))


def read_lock_file(cache_dir: String) raises -> DatasetLock:
    """Read and check `<cache_dir>/data.lock`.

    Raises:
        Error: no such file, or the text is not a valid lock.
    """
    return decode_lock(Path(_lock_path(cache_dir)).read_text())
