# Check a cache directory against a manifest: every file present, its size and
# its sha256 equal to what the manifest records. The sha256 is komira_crypto's,
# streamed in fixed chunks, so a file of any size is hashed in constant memory.
#
# A file's status is one of:
#   VERIFIED         the size and the sha256 are recorded and both match
#   UNRECORDED       present, every recorded value matches, but the size or the
#                    sha256 is not recorded yet; the observed values are in the
#                    result so they can be recorded
#   MISSING          no regular file at the path
#   SIZE_MISMATCH    the size differs from the recorded one (the file is not
#                    hashed: a truncated download is refused cheaply)
#   SHA_MISMATCH     the sizes agree and the sha256 differs
#
# Row counts are carried by the manifest and the lock (lock.mojo); the verifier
# does not read Parquet footers, so it does not check them.

from std.io import FileHandle
from std.os import stat
from std.os.path import isfile

from komira_crypto import Sha256, hex_lower_array_32

from .manifest import DatasetFile, DatasetManifest

comptime FILE_VERIFIED: Int = 0
comptime FILE_UNRECORDED: Int = 1
comptime FILE_MISSING: Int = 2
comptime FILE_SIZE_MISMATCH: Int = 3
comptime FILE_SHA_MISMATCH: Int = 4

comptime _HASH_CHUNK_BYTES: Int = 4 * 1024 * 1024


def file_status_name(status: Int) -> String:
    """The word a report prints for a `FILE_*` status."""
    if status == FILE_VERIFIED:
        return String("VERIFIED")
    if status == FILE_UNRECORDED:
        return String("UNRECORDED")
    if status == FILE_MISSING:
        return String("MISSING")
    if status == FILE_SIZE_MISMATCH:
        return String("SIZE_MISMATCH")
    if status == FILE_SHA_MISMATCH:
        return String("SHA_MISMATCH")
    return String("UNKNOWN")


struct FileCheck(Copyable, Movable):
    """What the verifier found for one manifest file."""

    var path: String
    var status: Int
    var observed_bytes: Int
    """The size on disk, or -1 for a missing file."""
    var observed_sha256: String
    """The sha256 of the content, or empty when it was not computed (a missing
    file, or a size mismatch)."""

    def __init__(
        out self,
        var path: String,
        status: Int,
        observed_bytes: Int,
        var observed_sha256: String,
    ):
        self.path = path^
        self.status = status
        self.observed_bytes = observed_bytes
        self.observed_sha256 = observed_sha256^


struct VerifyReport(Copyable, Movable):
    """The result of `verify_dataset`: one `FileCheck` per manifest file, in
    the manifest's order."""

    var dataset: String
    var scale: String
    var checks: List[FileCheck]

    def __init__(
        out self, var dataset: String, var scale: String, var checks: List[FileCheck]
    ):
        self.dataset = dataset^
        self.scale = scale^
        self.checks = checks^

    def count(self, status: Int) -> Int:
        var n = 0
        for i in range(len(self.checks)):
            if self.checks[i].status == status:
                n += 1
        return n

    def is_verified(self) -> Bool:
        """True when every file is VERIFIED."""
        return self.count(FILE_VERIFIED) == len(self.checks)

    def is_usable(self) -> Bool:
        """True when every file is present and matches whatever is recorded:
        each is VERIFIED or UNRECORDED."""
        return self.count(FILE_VERIFIED) + self.count(FILE_UNRECORDED) == len(self.checks)

    def render(self) -> String:
        """One line per file, `<status> <bytes> <path>`, then a summary line."""
        var out = String("dataset ") + self.dataset + " " + self.scale + "\n"
        for i in range(len(self.checks)):
            ref c = self.checks[i]
            out += file_status_name(c.status) + " " + String(c.observed_bytes) + " " + c.path + "\n"
        out += (
            String(len(self.checks))
            + " files: "
            + String(self.count(FILE_VERIFIED))
            + " verified, "
            + String(self.count(FILE_UNRECORDED))
            + " unrecorded, "
            + String(len(self.checks) - self.count(FILE_VERIFIED) - self.count(FILE_UNRECORDED))
            + " failed\n"
        )
        return out^


def _join_path(dir: String, rel: String) -> String:
    if dir.as_bytes()[dir.byte_length() - 1] == 0x2F:
        return dir + rel
    return dir + "/" + rel


def sha256_of_file(path: String) raises -> String:
    """The sha256 of the file at `path` as 64 lowercase hex characters, read
    in 4 MiB chunks.

    Raises:
        Error: the file cannot be opened or read.
    """
    var h = FileHandle(path, "r")
    var hasher = Sha256()
    while True:
        var chunk = h.read_bytes(_HASH_CHUNK_BYTES)
        if len(chunk) == 0:
            break
        hasher.update(Span(chunk))
    var out = Array[UInt8, 32](fill=UInt8(0))
    hasher.finalize_into(out)
    return hex_lower_array_32(out)


def _check_file(cache_dir: String, f: DatasetFile) raises -> FileCheck:
    var full = _join_path(cache_dir, f.path)
    if not isfile(full):
        return FileCheck(f.path.copy(), FILE_MISSING, -1, String())
    var size = Int(stat(full).st_size)
    if f.has_bytes() and size != f.expected_bytes:
        return FileCheck(f.path.copy(), FILE_SIZE_MISMATCH, size, String())
    var digest = sha256_of_file(full)
    if f.has_sha256() and digest != f.expected_sha256:
        return FileCheck(f.path.copy(), FILE_SHA_MISMATCH, size, digest^)
    if f.has_bytes() and f.has_sha256():
        return FileCheck(f.path.copy(), FILE_VERIFIED, size, digest^)
    return FileCheck(f.path.copy(), FILE_UNRECORDED, size, digest^)


def verify_dataset(manifest: DatasetManifest, cache_dir: String) raises -> VerifyReport:
    """Check every file of `manifest` under `cache_dir`.

    A symbolic link inside the cache directory is followed. The manifest is
    validated first, so a path that could leave the directory is refused.

    Raises:
        Error: an invalid manifest, an empty `cache_dir`, or a file that
            exists and cannot be read.
    """
    manifest.validate()
    if cache_dir.byte_length() == 0:
        raise Error("verify_dataset: the cache directory is empty")
    var checks = List[FileCheck]()
    for i in range(len(manifest.files)):
        checks.append(_check_file(cache_dir, manifest.files[i]))
    return VerifyReport(manifest.name.copy(), manifest.scale.copy(), checks^)
