"""Load-time cases of the platform table (run by tools/build/tests/functional/platform_table/BUCK)."""

load(
    "@komira//tools/build/platforms:table.bzl",
    "PLATFORMS",
    "constraints",
    "host_refusal",
    "host_row",
    "none",
    "pending",
    "pin",
    "registered_names",
    "reserved_names",
    "table_refusals",
)

def _host(os, arch):
    # What `host_info()` returns, for the fields the table reads.
    return struct(
        os = struct(is_linux = os == "linux", is_macos = os == "macos"),
        arch = struct(is_aarch64 = arch == "aarch64", is_x86_64 = arch == "x86_64"),
    )

def _edit(row_name, field = None, value = None, role = None, pin_value = None, drop_role = None, drop_field = None):
    # A copy of the real table with one change: the loaded one is frozen.
    t = {}
    for n, r in PLATFORMS.items():
        r2 = dict(r)
        r2["assets"] = dict(r["assets"])
        t[n] = r2
    r = t[row_name]
    if drop_field:
        r.pop(drop_field)
    if field:
        r[field] = value
    if drop_role:
        r["assets"].pop(drop_role)
    if role:
        r["assets"][role] = pin_value
    return t

_GOOD_SHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# (what the case is, the table it checks, a sentence its refusals must contain; None: no refusal at all)
_TABLE_CASES = [
    ("the table as committed", PLATFORMS, None),
    ("a pin missing from a registered linux row", _edit("linux-x86_64", drop_role = "rustc"), "row linux-x86_64: missing pin `rustc`"),
    ("a pin missing from the macOS row", _edit("darwin-arm64", drop_role = "zig"), "row darwin-arm64: missing pin `zig`"),
    ("a pin missing from the reserved row", _edit("linux-arm64", drop_role = "protoc"), "row linux-arm64: missing pin `protoc`"),
    ("a registered row with a pending pin", _edit("darwin-arm64", role = "mojo_compiler", pin_value = pending("later")), "row darwin-arm64: pin `mojo_compiler` is pending, but the row is registered"),
    ("a registered row with a pending container base", _edit("linux-x86_64", field = "oci_base", value = pending("later")), "row linux-x86_64: pin `oci_base` is pending, but the row is registered"),
    ("a pending pin with no reason", _edit("linux-arm64", role = "busybox", pin_value = pending("")), "row linux-arm64: pin `busybox` is `pending` with no reason"),
    ("a sha256 that is not 64 hex digits", _edit("linux-x86_64", role = "zig", pin_value = pin("zig", "https://example.com/zig", "abc")), "row linux-x86_64: pin `zig`: sha256 is not 64 lowercase hex digits"),
    ("an upper-case sha256", _edit("linux-x86_64", role = "zig", pin_value = pin("zig", "https://example.com/zig", _GOOD_SHA.upper())), "sha256 is not 64 lowercase hex digits"),
    ("a url that is not https", _edit("linux-x86_64", role = "zig", pin_value = pin("zig", "http://example.com/zig", _GOOD_SHA)), "row linux-x86_64: pin `zig`: url is not https"),
    ("a pin with no url", _edit("linux-x86_64", role = "zig", pin_value = pin("zig", "", _GOOD_SHA)), "row linux-x86_64: pin `zig` has no `url`"),
    ("a pin with no name", _edit("linux-x86_64", role = "zig", pin_value = pin("", "https://example.com/zig", _GOOD_SHA)), "row linux-x86_64: pin `zig` has no `name`"),
    ("none for a pin that must be real", _edit("darwin-arm64", role = "rustc", pin_value = none("not needed")), "row darwin-arm64: pin `rustc` is `none(...)`"),
    ("none with no reason", _edit("darwin-arm64", role = "libgcc", pin_value = none("")), "row darwin-arm64: pin `libgcc` is `none` with no reason"),
    ("bundles with no container base", _edit("linux-x86_64", field = "oci_base", value = none("no")), "row linux-x86_64: bundles are a product of this row, but `oci_base` is none"),
    ("a pin role nobody reads", _edit("linux-x86_64", role = "cmake", pin_value = pin("cmake", "https://example.com/cmake", _GOOD_SHA)), "row linux-x86_64: unknown pin `cmake`"),
    ("a field missing", _edit("linux-x86_64", drop_field = "target_cpu"), "row linux-x86_64: missing field `target_cpu`"),
    ("the zig triple missing", _edit("darwin-arm64", drop_field = "zig_triple"), "row darwin-arm64: missing field `zig_triple`"),
    ("an unknown field", _edit("linux-x86_64", field = "cpu_floor", value = "x"), "row linux-x86_64: unknown field `cpu_floor`"),
    ("an empty runtime library list", _edit("linux-x86_64", field = "runtime_libs", value = []), "row linux-x86_64: `runtime_libs` is empty"),
    ("an empty CPU floor", _edit("darwin-arm64", field = "target_cpu", value = ""), "row darwin-arm64: `target_cpu` is empty"),
    ("an object format that is neither", _edit("linux-x86_64", field = "object_format", value = "pe"), "row linux-x86_64: object_format `pe`"),
    ("constraints that are not the row's os and cpu", _edit("linux-x86_64", field = "constraints", value = ["prelude//os/constraints:linux"]), "row linux-x86_64: constraints are"),
    ("two rows sharing a property key", _edit("linux-arm64", field = "re_key", value = "linux_properties"), "`re_key` `linux_properties` is also row"),
    ("two rows sharing a host", _edit("linux-arm64", field = "host", value = {"arch": "x86_64", "os": "linux"}), "`host` linux x86_64 is also row"),
    ("a row named for another platform", _edit("linux-arm64", field = "cpu", value = "x86_64"), "row linux-arm64: named for neither its os nor its cpu"),
]

# (os, arch) of a host_info(), the row it selects (None: none), a sentence its refusal must contain.
_HOST_CASES = [
    ("linux", "x86_64", "linux-x86_64", None),
    ("macos", "aarch64", "darwin-arm64", None),
    ("linux", "aarch64", None, "reserves a row for but does not build for yet"),
    ("macos", "x86_64", None, "no platform row matches this host (os macos, arch x86_64)"),
    ("other", "other", None, "no platform row matches this host (os other, arch other)"),
]

def platform_table_cases():
    for what, table, want in _TABLE_CASES:
        got = table_refusals(table)
        if want == None:
            if got:
                fail("platform table: {} was refused: {}".format(what, got))
        elif not [g for g in got if want in g]:
            fail("platform table: {}: expected a refusal containing `{}`, got {}".format(what, want, got))
    for os, arch, row, why in _HOST_CASES:
        h = _host(os, arch)
        if host_row(h) != row:
            fail("platform table: host {} {} selects {}, expected {}".format(os, arch, host_row(h), row))
        refusal = host_refusal(h)
        if (refusal == None) != (why == None) or (why != None and why not in refusal):
            fail("platform table: host {} {}: refusal is {}, expected {}".format(os, arch, refusal, why))
    if registered_names() != ["linux-x86_64", "darwin-arm64"]:
        fail("platform table: registered rows are {}, expected linux-x86_64 then darwin-arm64 (the first match of an action that states no os is linux)".format(registered_names()))
    if reserved_names() != ["linux-arm64"]:
        fail("platform table: reserved rows are {}, expected linux-arm64".format(reserved_names()))

    # The linux-x86_64 platform's constraints key its configuration hash
    # (test 18 of run_tests.sh pins that hash): any change here re-keys every
    # action.
    if constraints("linux-x86_64") != ["prelude//os/constraints:linux", "prelude//cpu/constraints:x86_64"]:
        fail("platform table: the constraints of linux-x86_64 changed: {}".format(constraints("linux-x86_64")))
