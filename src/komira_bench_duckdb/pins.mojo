# The DuckDB versions the benchmarks accept as its opponent, and the check of a
# user-supplied file against them. DuckDB is never shipped or downloaded by
# this package: the user passes the path of a binary they obtained themselves,
# and a run goes ahead only when the file's SHA-256 is the pinned one for the
# version the run asked for.
#
# The table follows third_party/duckdb of this repository: the same release
# (the version and the commit it was built from), the digest and size of the
# release's linux amd64 archive, and the digest and size of the `duckdb` file
# inside it. A file that matches the archive's digest is reported as such, so
# the message can say to unpack it first.

from std.pathlib import Path

from komira_crypto import hex_lower_array_32, sha256

comptime PIN_PINNED: Int = 0
comptime PIN_IS_ARCHIVE: Int = 1
comptime PIN_MISMATCH: Int = 2
comptime PIN_UNKNOWN_VERSION: Int = 3

comptime DEFAULT_DUCKDB_VERSION: String = "1.5.6"


struct DuckDbPin(Copyable, Movable):
    """One accepted DuckDB release."""

    var version: String
    var commit: String
    var archive_sha256: String
    var archive_size: Int
    var binary_sha256: String
    var binary_size: Int

    def __init__(
        out self,
        version: String,
        commit: String,
        archive_sha256: String,
        archive_size: Int,
        binary_sha256: String,
        binary_size: Int,
    ):
        self.version = version
        self.commit = commit
        self.archive_sha256 = archive_sha256
        self.archive_size = archive_size
        self.binary_sha256 = binary_sha256
        self.binary_size = binary_size


def duckdb_pins() -> List[DuckDbPin]:
    """Every accepted release."""
    var pins = List[DuckDbPin]()
    pins.append(
        DuckDbPin(
            String("1.5.6"),
            String("069cc9f9b5be802405797faecc284961b07c70ef"),
            String("6e89deac1ebbc36eed0291caf8b567b030c7b86ac35998f71854e22b3c5d5e2f"),
            21294383,
            String("61238cfbe9dfeaad4bcfcd8a48f6f7123dae2e9603aaadb1f77a4217aeb8980c"),
            61932504,
        )
    )
    return pins^


def find_pin(version: String) -> Int:
    """The index of the pin for `version` (no leading `v`), or -1."""
    var pins = duckdb_pins()
    for i in range(len(pins)):
        if pins[i].version == version:
            return i
    return -1


struct PinCheck(Copyable, Movable):
    """What checking a file against the pin found."""

    var status: Int
    var version: String
    var sha256: String
    var size: Int

    def __init__(out self, status: Int, version: String, sha256: String, size: Int):
        self.status = status
        self.version = version
        self.sha256 = sha256
        self.size = size

    def is_pinned(self) -> Bool:
        return self.status == PIN_PINNED

    def describe(self) -> String:
        if self.status == PIN_PINNED:
            return String("PINNED duckdb ") + self.version + String(" sha256 ") + self.sha256
        if self.status == PIN_IS_ARCHIVE:
            return String("the file is the duckdb ") + self.version + String(" release archive (sha256 ") + self.sha256 + String("), not the binary: unpack it and pass the `duckdb` file")
        if self.status == PIN_UNKNOWN_VERSION:
            return String("no pin for duckdb ") + self.version
        return (
            String("sha256 ") + self.sha256 + String(" (") + String(self.size)
            + String(" bytes) is not the pinned duckdb ") + self.version + String(" binary")
        )


def check_against_pins(
    data: Span[UInt8, _], pins: List[DuckDbPin], version: String
) -> PinCheck:
    """Check the bytes of a file against the pin for `version` in `pins`."""
    var digest = hex_lower_array_32(sha256(data))
    for i in range(len(pins)):
        if pins[i].version != version:
            continue
        if digest == pins[i].binary_sha256 and len(data) == pins[i].binary_size:
            return PinCheck(PIN_PINNED, version, digest, len(data))
        if digest == pins[i].archive_sha256 and len(data) == pins[i].archive_size:
            return PinCheck(PIN_IS_ARCHIVE, version, digest, len(data))
        return PinCheck(PIN_MISMATCH, version, digest, len(data))
    return PinCheck(PIN_UNKNOWN_VERSION, version, digest, len(data))


def check_duckdb_bytes(data: Span[UInt8, _], version: String) -> PinCheck:
    """Check the bytes of a file against the pin table for `version`."""
    return check_against_pins(data, duckdb_pins(), version)


def check_duckdb_file(path: String, version: String) raises -> PinCheck:
    """Read the file at `path` and check it against the pin table for
    `version`. Raises when the file cannot be read."""
    var data = Path(path).read_bytes()
    return check_duckdb_bytes(Span(data), version)
