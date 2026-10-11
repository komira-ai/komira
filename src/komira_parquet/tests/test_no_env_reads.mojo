# A scan of the package's own sources. Every source the library compiles is
# staged as this test's data, at src/<path>; the test reads each one and fails
# if any:
#   * reads the environment (the decode arms are chosen by setters, never
#     by an environment variable),
#   * names a raw pointer in the signature of a public function (one whose
#     name does not start with a single underscore): pointers are taken from
#     Spans inside the bodies only,
#   * rebuilds an address from an integer, or names a wildcard origin,
#   * imports a komira package that is not one of the library's deps (or
#     the package itself), or names komira_obs, komira_serde or komira_core.
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
    "bloom_pruner.mojo",
    "bloom_reader.mojo",
    "byte_stream_split.mojo",
    "decimal_decode.mojo",
    "decode_arm_trace.mojo",
    "decode_helpers.mojo",
    "def_level_bitmap.mojo",
    "delta.mojo",
    "delta_byte_array.mojo",
    "dict_gather_fused.mojo",
    "dictionary.mojo",
    "dictionary_resolve.mojo",
    "file_reader.mojo",
    "footer_header.mojo",
    "gather.mojo",
    "gather_byte_array.mojo",
    "gather_common.mojo",
    "gather_dict.mojo",
    "metadata_parser.mojo",
    "nested.mojo",
    "null_expand.mojo",
    "num_rows_cache.mojo",
    "page_header_parser.mojo",
    "partition_pred_bridge.mojo",
    "payload_sel_trace.mojo",
    "plain.mojo",
    "plain_flba.mojo",
    "rle.mojo",
    "rle_bitunpack.mojo",
    "scan_copy_trace.mojo",
    "selection_vector.mojo",
    "staged_filter_trace.mojo",
    "thrift_compact.mojo",
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
    # Not vacuous: the public surface was found (the decoders, their
    # constructors and methods, the arm counters and setters, ...).
    assert_true(seen >= 40, "found only " + String(seen) + " public signatures")


def test_no_address_from_an_integer() raises:
    var banned: List[String] = [
        "unsafe_from_" + "address",
        "Mut" + "AnyOrigin",
        "Immut" + "AnyOrigin",
        "Mut" + "ExternalOrigin",
    ]
    var files = materialize[_FILES]()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j],
            )


def _import_root(line: String) -> String:
    """The top-level package a `from X...` / `import X...` line names, or ""
    for any other line (and for a relative import)."""
    var s = String(line.lstrip())
    var rest = String("")
    if s.startswith("from "):
        rest = String(s[byte=5:])
    elif s.startswith("import "):
        rest = String(s[byte=7:])
    else:
        return ""
    var end = rest.byte_length()
    var stops: List[String] = [".", " ", ",", "("]
    for k in range(len(stops)):
        var at = rest.find(stops[k])
        if at >= 0 and at < end:
            end = at
    return String(rest[byte=0:end])


def test_imports_only_its_deps() raises:
    # The package imports only the deps its BUCK file lists. An import outside
    # them would not build, but adding the dep would make it build; this list
    # makes a new dep a change to the test too, and komira_obs and
    # komira_serde are refused outright.
    var allowed: List[String] = [
        "komira_arrow",
        "komira_async",
        "komira_atomic_alias",
        "komira_buffer",
        "komira_collections",
        "komira_dynamic_filter",
        "komira_fs",
        "komira_parquet",
        "komira_parquet_api",
        "komira_parquet_codec",
        "komira_plan_expr",
        "komira_simd",
    ]
    var banned: List[String] = ["komira_obs", "komira_serde", "komira_" + "core"]
    var files = materialize[_FILES]()
    var seen = 0
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j],
            )
        var lines = text.split("\n")
        for k in range(len(lines)):
            var root = _import_root(String(lines[k]))
            if not root.startswith("komira"):
                continue
            seen += 1
            var ok = False
            for j in range(len(allowed)):
                if root == allowed[j]:
                    ok = True
            assert_true(ok, files[i] + " imports " + root + ", not a dep")
    # Not vacuous: the decoders import komira_arrow and komira_buffer, the
    # arm counters komira_atomic_alias, the footer readers komira_fs and
    # komira_parquet_api.
    assert_true(seen >= 30, "found only " + String(seen) + " komira imports")


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
    assert_equal(_count(_read("rle.mojo"), "\nstruct RleDecoder("), 1)
    assert_equal(_count(_read("decode_arm_trace.mojo"), "\ndef set_delta_page_memcpy_enabled("), 1)
    assert_true(_read("rle_bitunpack.mojo").byte_length() > 10000)
    assert_equal(_count(_read("thrift_compact.mojo"), "\nstruct ThriftCompactReader["), 1)
    assert_equal(_count(_read("file_reader.mojo"), "\nstruct ParquetFileReader["), 1)


def main() raises:
    test_no_environment_read()
    test_no_raw_pointer_in_a_public_signature()
    test_no_address_from_an_integer()
    test_imports_only_its_deps()
    test_the_scan_saw_the_package()
    print("OK")
