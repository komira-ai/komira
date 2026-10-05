# A scan of the package's own sources. Every source the library compiles is
# staged as this test's data, at src/<path>; the test reads each one and fails
# if any:
#   * reads the environment (the snappy decoder is chosen by a setter, never
#     by an environment variable),
#   * names a raw pointer in the signature of a public function (one whose
#     name does not start with a single underscore): pointers are taken from
#     Spans inside the bodies only,
#   * rebuilds an address from an integer,
#   * names the engine this package was split out of.
# It also checks that the files it read are every staged one, subdirectories
# included, so a new module that the scan does not read fails it.
from std.os import listdir
from std.os.path import isdir
from std.testing import assert_equal, assert_true


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _read(name: String) raises -> String:
    with open(String("src/") + name, "r") as f:
        return f.read()


comptime _FILES: List[String] = [
    "__init__.mojo",
    "brotli/__init__.mojo",
    "brotli/brotli_ffi.mojo",
    "compression.mojo",
    "crc32c.mojo",
    "lz4_frame/__init__.mojo",
    "lz4_frame/lz4_ffi.mojo",
    "snappy/__init__.mojo",
    "snappy/decompress.mojo",
    "snappy/format.mojo",
    "snappy/snappy_ffi.mojo",
    "snappy/varint.mojo",
    "zstd/__init__.mojo",
    "zstd/zstd_ffi.mojo",
]


def _staged(dir: String, mut found: List[String]) raises:
    """Every file under src/<dir>, as a path relative to src/."""
    var root = String("src") if dir == "" else String("src/") + dir
    var names = listdir(root)
    for i in range(len(names)):
        var rel = names[i] if dir == "" else dir + "/" + names[i]
        if isdir(String("src/") + rel):
            _staged(rel, found)
        else:
            found.append(rel)


def _is_public(name: String) -> Bool:
    # `__init__`, `__eq__`, ... are public; `_x` is package-private.
    return not name.startswith("_") or name.startswith("__")


def _public_signatures(text: String) raises -> List[String]:
    """The full text of each public `def` signature in `text`: from the line
    holding `def` to the line that ends the signature with `:`."""
    var lines = text.split("\n")
    var sigs = List[String]()
    var i = 0
    while i < len(lines):
        var line = String(lines[i])
        var stripped = String(line.lstrip())
        if stripped.startswith("def "):
            var rest = String(stripped[byte=4:])
            var end = rest.byte_length()
            var paren = rest.find("(")
            var bracket = rest.find("[")
            if paren >= 0 and paren < end:
                end = paren
            if bracket >= 0 and bracket < end:
                end = bracket
            var name = String(rest[byte=0:end])
            var sig = line
            var j = i
            while not String(lines[j].rstrip()).endswith(":") and j + 1 < len(lines):
                j += 1
                sig += "\n" + String(lines[j])
            if _is_public(name):
                sigs.append(sig)
            i = j
        i += 1
    return sigs^


def test_no_environment_read() raises:
    var banned: List[String] = [
        "getenv",
        "setenv",
        "_env_",
        "_read_env",
    ]
    var files = materialize[_FILES]()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j] + "; the package reads no environment",
            )


def test_no_raw_pointer_in_a_public_signature() raises:
    var files = materialize[_FILES]()
    var seen = 0
    for i in range(len(files)):
        var sigs = _public_signatures(_read(files[i]))
        seen += len(sigs)
        for j in range(len(sigs)):
            assert_equal(
                _count(sigs[j], "UnsafePointer"),
                0,
                files[i] + ": a public signature names a raw pointer:\n" + sigs[j],
            )
    # Not vacuous: the public surface was found (decompress, compress, the
    # snappy entries, crc32c, ...).
    assert_true(seen >= 15, "found only " + String(seen) + " public signatures")


def test_no_address_from_an_integer() raises:
    var files = materialize[_FILES]()
    for i in range(len(files)):
        assert_equal(
            _count(_read(files[i]), "unsafe_from_" + "address"),
            0,
            files[i] + " rebuilds an address from an integer",
        )


def test_no_internal_engine_name() raises:
    # Spelled in two halves so this file does not hold the word either.
    var word = String("tho") + "rium"
    var files = materialize[_FILES]()
    for i in range(len(files)):
        assert_equal(
            _count(_read(files[i]).lower(), word),
            0,
            files[i] + " names the engine the package was split out of",
        )


def test_the_scan_saw_the_package() raises:
    # Every staged source is one the scan reads: a new file joins _FILES.
    var files = materialize[_FILES]()
    var staged = List[String]()
    _staged("", staged)
    assert_equal(len(staged), len(files), "src/ holds a file the scan does not read")
    for i in range(len(staged)):
        var known = False
        for j in range(len(files)):
            if staged[i] == files[j]:
                known = True
        assert_true(known, "src/" + staged[i] + " is staged but not scanned")
    # Not vacuous: each file is the package's, whole.
    assert_equal(_count(_read("compression.mojo"), "\ndef decompress["), 1)
    assert_equal(_count(_read("snappy/snappy_ffi.mojo"), "\ndef set_snappy_decoder("), 1)
    assert_true(_read("snappy/decompress.mojo").byte_length() > 10000)


def main() raises:
    test_no_environment_read()
    test_no_raw_pointer_in_a_public_signature()
    test_no_address_from_an_integer()
    test_no_internal_engine_name()
    test_the_scan_saw_the_package()
    print("OK")
