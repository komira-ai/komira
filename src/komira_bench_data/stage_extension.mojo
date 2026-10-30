# The tpch extension file, as native code that DuckDB will load and run: it is
# pinned, and nothing is unpacked or loaded that the pin table does not name.
#
# The pinned artifact is the file as DuckDB's extension repository serves it,
# the gzip, per DuckDB release and platform. `prepare_extension` reads the gzip
# once, checks its size and sha256 against the pin table, refuses anything else
# (no pin for the release and platform, a different file, another size, or not
# a gzip) BEFORE DuckDB is started, unpacks the very bytes it hashed into a
# directory that only this process writes (mode 0700, made fresh), and returns
# the path of that private copy. DuckDB is then told to LOAD the private copy,
# and the read-back install path must be that copy (stage.mojo), so a file
# replaced after the check is never the file that runs.
#
# The one pin below was measured, not published: DuckDB gives no checksum for
# its extensions, so a reviewer's run downloaded the file for 1.5.6 linux_amd64
# from the extension repository and recorded its sha256 and size. It is trust on
# first use as of that measurement, nothing more. To add a platform or a release:
# download the .gz yourself, read the file's sha256 and size
# with `sha256sum` and `wc -c`, have a second person repeat it, and add the
# line `extension_pin_line` prints.

from std.os import listdir, makedirs, mkdir, remove, rmdir
from std.os.path import exists, isdir, islink
from std.pathlib import Path

from komira_compression.compression_codecs import Gzip
from komira_crypto import hex_lower_array_32, sha256

comptime DEFAULT_EXTENSION_PLATFORM: String = "linux_amd64"
comptime EXT_PINNED: Int = 0
comptime EXT_UNRECORDED: Int = 1
comptime EXT_MISMATCH: Int = 2
comptime EXTENSION_FILE_NAME: String = "tpch.duckdb_extension"
comptime _MAX_UNPACKED_BYTES: Int = 256 * 1024 * 1024


struct ExtensionPin(Copyable, Movable):
    """One accepted tpch extension: for a DuckDB release and a platform, the
    sha256 and size of the gzip as the extension repository serves it."""

    var version: String
    var platform: String
    var sha256: String
    var size: Int

    def __init__(out self, var version: String, var platform: String, var sha256: String, size: Int):
        self.version = version^
        self.platform = platform^
        self.sha256 = sha256^
        self.size = size


def tpch_extension_pins() -> List[ExtensionPin]:
    """Every accepted extension: exactly one, measured from the repository's
    file for DuckDB 1.5.6 on linux_amd64 (see the header)."""
    var out = List[ExtensionPin]()
    out.append(
        ExtensionPin(
            String("1.5.6"),
            String("linux_amd64"),
            String("51959cc795f6ea8c95cf8cc6cc4065358998ce959bf863e21ff1aa471c06bc41"),
            5649100,
        )
    )
    return out^


def extension_pin_line(version: String, platform: String, sha256: String, size: Int) -> String:
    """The line `tpch_extension_pins` takes for an observed extension file."""
    return (
        String('    out.append(ExtensionPin("') + version + String('", "') + platform
        + String('", "') + sha256 + String('", ') + String(size) + String("))")
    )


struct ExtensionCheck(Copyable, Movable):
    """What checking a gzip against the pins found."""

    var status: Int
    var version: String
    var platform: String
    var sha256: String
    var size: Int

    def __init__(
        out self, status: Int, var version: String, var platform: String, var sha256: String, size: Int
    ):
        self.status = status
        self.version = version^
        self.platform = platform^
        self.sha256 = sha256^
        self.size = size

    def describe(self) -> String:
        if self.status == EXT_PINNED:
            return String("PINNED tpch extension ") + self.version + " " + self.platform + " sha256 " + self.sha256
        var seen = String("sha256 ") + self.sha256 + " (" + String(self.size) + " bytes)"
        if self.status == EXT_MISMATCH:
            return seen + " is not the pinned tpch extension for duckdb " + self.version + " " + self.platform
        return (
            String("no pin for the tpch extension of duckdb ") + self.version + " " + self.platform
            + "; the file has " + seen + ". To pin it, see the header of stage_extension.mojo; the line would be:\n"
            + extension_pin_line(self.version, self.platform, self.sha256, self.size)
        )


def check_extension_bytes(
    data: Span[UInt8, _], pins: List[ExtensionPin], version: String, platform: String
) -> ExtensionCheck:
    """Check the bytes of a gzip against `pins`: PINNED when a pin for the
    release and platform names this sha256 and size, MISMATCH when a pin exists
    and differs (in content or in size), UNRECORDED when none exists."""
    var digest = hex_lower_array_32(sha256(data))
    var size = len(data)
    for i in range(len(pins)):
        if pins[i].version == version and pins[i].platform == platform:
            if pins[i].sha256 == digest and pins[i].size == size:
                return ExtensionCheck(EXT_PINNED, version.copy(), platform.copy(), digest^, size)
            return ExtensionCheck(EXT_MISMATCH, version.copy(), platform.copy(), digest^, size)
    return ExtensionCheck(EXT_UNRECORDED, version.copy(), platform.copy(), digest^, size)


struct PreparedExtension(Copyable, Movable):
    """The result of `prepare_extension`."""

    var check: ExtensionCheck
    """The pin check of the gzip (always PINNED here)."""
    var private_dir: String
    var path: String
    """The private copy DuckDB must load."""
    var unpacked_sha256: String
    var unpacked_size: Int

    def __init__(
        out self,
        var check: ExtensionCheck,
        var private_dir: String,
        var path: String,
        var unpacked_sha256: String,
        unpacked_size: Int,
    ):
        self.check = check^
        self.private_dir = private_dir^
        self.path = path^
        self.unpacked_sha256 = unpacked_sha256^
        self.unpacked_size = unpacked_size


def prepare_extension(
    gz_path: String,
    private_dir: String,
    version: String,
    platform: String,
    pins: List[ExtensionPin],
) raises -> PreparedExtension:
    """Check the gzip at `gz_path` against `pins`, then unpack it into the
    fresh directory `private_dir` (created with mode 0700; it must not exist).
    Nothing is written, and nothing is created, unless the gzip is PINNED.

    Raises:
        Error: the file cannot be read; no pin, or another file or size than
            the pin's; the gzip's recorded unpacked size is zero or above
            256 MiB or the stream does not unpack to it; `private_dir` exists.
    """
    var data = Path(gz_path).read_bytes()
    var check = check_extension_bytes(Span(data), pins, version, platform)
    if check.status != EXT_PINNED:
        raise Error(check.describe())
    var n = len(data)
    if n < 18:
        raise Error("tpch extension: the pinned file is too short to be a gzip")
    var isize = (
        Int(data[n - 4]) | (Int(data[n - 3]) << 8) | (Int(data[n - 2]) << 16) | (Int(data[n - 1]) << 24)
    )
    if isize < 1 or isize > _MAX_UNPACKED_BYTES:
        raise Error("tpch extension: the gzip records an unpacked size of " + String(isize) + " bytes")
    var unpacked = Gzip.decompress(Span(data), isize)
    if len(unpacked) != isize:
        raise Error("tpch extension: the gzip unpacked to " + String(len(unpacked)) + " bytes, not " + String(isize))
    if exists(private_dir):
        raise Error("tpch extension: " + private_dir + " already exists; remove it by hand")
    makedirs(_parent(private_dir), exist_ok=True)
    mkdir(private_dir, 0o700)
    var path = private_dir + "/" + String(EXTENSION_FILE_NAME)
    Path(path).write_bytes(Span(unpacked))
    return PreparedExtension(
        check^, private_dir.copy(), path^, hex_lower_array_32(sha256(Span(unpacked))), len(unpacked)
    )


def _parent(path: String) -> String:
    var b = path.as_bytes()
    var i = len(b)
    while i > 1 and b[i - 1] != UInt8(0x2F):
        i -= 1
    return String(path[byte=0:i - 1]) if i > 1 else String("/")


def remove_tree(path: String):
    """Remove `path` and everything under it (a link is removed, not
    followed). Failures are ignored: this is cleanup."""
    try:
        if islink(path):
            remove(path)
        elif isdir(path):
            for name in listdir(path):
                remove_tree(path + "/" + name)
            rmdir(path)
        elif exists(path):
            remove(path)
    except:
        pass
