"""Load-time cases of the platform table (run by tools/build/tests/functional/platform_table/BUCK)."""

load(
    "@komira//tools/build/platforms:table.bzl",
    "PLATFORMS",
    "UNPINNED_IMAGE",
    "by_target_os",
    "constraints",
    "host_refusal",
    "host_row",
    "image",
    "none",
    "pending",
    "pin",
    "placeholder",
    "preflight_image",
    "registered_names",
    "release_version",
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

def _oci_without_last_layer_size():
    oci = dict(PLATFORMS["linux-x86_64"]["oci_base"])
    oci["layer_sizes"] = list(oci["layer_sizes"])[:-1]
    return oci

def _oci_with_config_size(z):
    oci = dict(PLATFORMS["linux-x86_64"]["oci_base"])
    oci["config_size"] = z
    return oci

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
    ("a pin role nobody reads", _edit("linux-x86_64", role = "cmake", pin_value = pin("cmake", "https://example.com/cmake", _GOOD_SHA, size = 1)), "row linux-x86_64: unknown pin `cmake`"),
    ("a field missing", _edit("linux-x86_64", drop_field = "target_cpu"), "row linux-x86_64: missing field `target_cpu`"),
    ("the zig triple missing", _edit("darwin-arm64", drop_field = "zig_triple"), "row darwin-arm64: missing field `zig_triple`"),
    ("an unknown field", _edit("linux-x86_64", field = "cpu_floor", value = "x"), "row linux-x86_64: unknown field `cpu_floor`"),
    ("an empty runtime library list", _edit("linux-x86_64", field = "runtime_libs", value = []), "row linux-x86_64: `runtime_libs` is empty"),
    ("an empty CPU floor", _edit("darwin-arm64", field = "target_cpu", value = ""), "row darwin-arm64: `target_cpu` is empty"),
    ("an object format that is neither", _edit("linux-x86_64", field = "object_format", value = "pe"), "row linux-x86_64: object_format `pe`"),
    ("constraints that are not the row's os and cpu", _edit("linux-x86_64", field = "constraints", value = ["prelude//os/constraints:linux"]), "row linux-x86_64: constraints are"),
    ("two rows sharing a property key", _edit("linux-arm64", field = "re_key", value = "linux_x86_64_properties"), "`re_key` `linux_x86_64_properties` is also row"),
    ("two rows sharing a host", _edit("linux-arm64", field = "host", value = {"arch": "x86_64", "os": "linux"}), "`host` linux x86_64 is also row"),
    ("a cache line that is not a power of two", _edit("linux-x86_64", field = "cache_line_bytes", value = 48), "row linux-x86_64: `cache_line_bytes` is not a power of two"),
    ("a page size of zero", _edit("darwin-arm64", field = "page_bytes", value = 0), "row darwin-arm64: `page_bytes` is not a power of two"),
    ("a feature nobody defines", _edit("linux-x86_64", field = "features", value = ["avx9000"]), "row linux-x86_64: feature `avx9000` is not one of"),
    ("unsorted features", _edit("linux-x86_64", field = "features", value = ["thp", "epoll"]), "row linux-x86_64: `features` must be a sorted list"),
    ("a golden hash that is not 16 hex digits", _edit("linux-x86_64", field = "golden_config_hash", value = "03cc"), "row linux-x86_64: `golden_config_hash` is not 16 lowercase hex digits"),
    ("a registered row with a pending golden hash", _edit("darwin-arm64", field = "golden_config_hash", value = pending("later")), "row darwin-arm64: `golden_config_hash` is a dict that is not `pending(reason)` of an unregistered row"),
    ("a golden hash recorded for a row with no platform", _edit("linux-arm64", field = "golden_config_hash", value = "03cc1a891c89e4be"), "row linux-arm64: `golden_config_hash` is recorded, but the row has no platform"),
    ("a pool that names no pool", _edit("linux-x86_64", field = "pool", value = "mojo-sized"), "row linux-x86_64: `pool` must be `pool=<name>`"),
    ("two rows sharing a pool", _edit("linux-arm64", field = "pool", value = "pool=mojo-sized"), "`pool` `pool=mojo-sized` is also row"),
    ("a zig digest that is not 64 hex digits", _edit("darwin-arm64", field = "zig_exe_sha256", value = "abc"), "row darwin-arm64: `zig_exe_sha256` is not 64 lowercase hex digits"),
    ("an applet list that is not sorted", _edit("darwin-arm64", field = "applets", value = ["sh", "cat"]), "row darwin-arm64: `applets` must be a non-empty sorted list"),
    ("a pending applet list in a registered row", _edit("darwin-arm64", field = "applets", value = pending("later")), "row darwin-arm64: `applets` is pending, but the row is registered"),
    ("the pixi pin missing from the macOS row", _edit("darwin-arm64", drop_role = "pixi"), "row darwin-arm64: missing pin `pixi`"),
    ("the pixi pin missing from the linux row", _edit("linux-x86_64", drop_role = "pixi"), "row linux-x86_64: missing pin `pixi`"),
    ("a registered row with a pending pixi", _edit("darwin-arm64", role = "pixi", pin_value = pending("later")), "row darwin-arm64: pin `pixi` is pending, but the row is registered"),
    ("a pixi pin that is not executable", _edit("linux-x86_64", role = "pixi", pin_value = pin("pixi", "https://github.com/prefix-dev/pixi/releases/download/v0.67.2/pixi-x86_64-unknown-linux-musl", _GOOD_SHA)), "row linux-x86_64: pin `pixi` is an executable, but is not pinned with `executable = True`"),
    ("a pixi pin whose url names no release", _edit("darwin-arm64", role = "pixi", pin_value = pin("pixi", "https://example.com/pixi", _GOOD_SHA, executable = True)), "row darwin-arm64: pin `pixi`: url names no release"),
    ("pixi pinned at two releases", _edit("darwin-arm64", role = "pixi", pin_value = pin("pixi", "https://github.com/prefix-dev/pixi/releases/download/v0.66.0/pixi-aarch64-apple-darwin", _GOOD_SHA, executable = True, size = 1)), "pin `pixi` names more than one release: 0.66.0 in darwin-arm64; 0.67.2 in linux-x86_64"),
    ("a busybox pin that is not executable", _edit("linux-x86_64", role = "busybox", pin_value = pin("busybox", "https://example.com/busybox", _GOOD_SHA)), "row linux-x86_64: pin `busybox` is an executable"),
    # The size is the last check of a pin, so every case above keeps its own refusal.
    ("a pin with no size", _edit("linux-x86_64", role = "zig", pin_value = pin("zig", "https://example.com/zig", _GOOD_SHA)), "row linux-x86_64: pin `zig` has no positive `size`: None"),
    ("a size of 0", _edit("darwin-arm64", role = "zig", pin_value = pin("zig", "https://example.com/zig", _GOOD_SHA, size = 0)), "row darwin-arm64: pin `zig` has no positive `size`: 0"),
    ("a negative size", _edit("linux-arm64", role = "zig", pin_value = pin("zig", "https://example.com/zig", _GOOD_SHA, size = -5)), "row linux-arm64: pin `zig` has no positive `size`: -5"),
    ("a size that is a string", _edit("linux-x86_64", role = "busybox", pin_value = pin("busybox", "https://example.com/busybox", _GOOD_SHA, executable = True, size = "1131168")), "row linux-x86_64: pin `busybox` has no positive `size`: \"1131168\""),
    ("a container base missing a layer size", _edit("linux-x86_64", field = "oci_base", value = _oci_without_last_layer_size()), "row linux-x86_64: pin `oci_base`: `config_size` and each of `layer_sizes` must be a positive size, one per layer"),
    # A config size of 0 is refused as absent (`has no`); a negative or non-int one reaches only the positive-size check.
    ("a container base with a config size of 0", _edit("linux-x86_64", field = "oci_base", value = _oci_with_config_size(0)), "row linux-x86_64: pin `oci_base` has no `config_size`"),
    ("a container base with a negative config size", _edit("linux-x86_64", field = "oci_base", value = _oci_with_config_size(-1)), "row linux-x86_64: pin `oci_base`: `config_size` and each of `layer_sizes` must be a positive size, one per layer"),
    ("a container base with a config size that is not an int", _edit("linux-x86_64", field = "oci_base", value = _oci_with_config_size("1024")), "row linux-x86_64: pin `oci_base`: `config_size` and each of `layer_sizes` must be a positive size, one per layer"),
    ("a pre-flight image pinned by digest", _edit("linux-x86_64", field = "preflight_image", value = image("docker.io/library/busybox@sha256:" + _GOOD_SHA)), None),
    ("a pre-flight image by tag", _edit("linux-x86_64", field = "preflight_image", value = image("docker.io/library/busybox:1.37")), "row linux-x86_64: `preflight_image` is not pinned by digest"),
    ("a pre-flight image with a tag and a short digest", _edit("linux-x86_64", field = "preflight_image", value = image("busybox@sha256:abc")), "row linux-x86_64: `preflight_image` is not pinned by digest"),
    ("the placeholder image written as a pin", _edit("linux-x86_64", field = "preflight_image", value = image(UNPINNED_IMAGE)), "row linux-x86_64: `preflight_image` is the placeholder image"),
    ("a registered row with a pending pre-flight image", _edit("linux-x86_64", field = "preflight_image", value = pending("later")), "row linux-x86_64: `preflight_image` is pending, but the row is registered"),
    ("a placeholder with no reason", _edit("linux-x86_64", field = "preflight_image", value = placeholder("")), "row linux-x86_64: `preflight_image` is `placeholder` with no reason"),
    ("a pre-flight image that is a bare string", _edit("darwin-arm64", field = "preflight_image", value = "busybox"), "row darwin-arm64: `preflight_image` is not `image(...)`"),
    ("the pre-flight image missing", _edit("linux-x86_64", drop_field = "preflight_image"), "row linux-x86_64: missing field `preflight_image`"),
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
    # what --preflight-image is given: the row's digest reference, or the unpinned placeholder
    want = PLATFORMS["linux-x86_64"]["preflight_image"].get("image") or UNPINNED_IMAGE
    if preflight_image("linux-x86_64") != want or preflight_image("darwin-arm64") != UNPINNED_IMAGE:
        fail("platform table: preflight_image() hands on {} and {}".format(preflight_image("linux-x86_64"), preflight_image("darwin-arm64")))
    if registered_names() != ["linux-x86_64", "darwin-arm64"]:
        fail("platform table: registered rows are {}, expected linux-x86_64 then darwin-arm64 (the first match of an action that states no os is linux)".format(registered_names()))
    if reserved_names() != ["linux-arm64"]:
        fail("platform table: reserved rows are {}, expected linux-arm64".format(reserved_names()))

    # //tools/build/toolchains:pixi selects by the target platform's os: each
    # registered row's own pixi, all one release.
    want_pixi = {
        "prelude//os/constraints:linux": ":pixi-0.67.2-x86_64-unknown-linux-musl",
        "prelude//os/constraints:macos": ":pixi-0.67.2-aarch64-apple-darwin",
    }
    if by_target_os("pixi") != want_pixi:
        fail("platform table: pixi by target os is {}, expected {}".format(by_target_os("pixi"), want_pixi))
    for n in registered_names():
        if release_version(n, "pixi") != "0.67.2":
            fail("platform table: row {} pins pixi {}, expected 0.67.2".format(n, release_version(n, "pixi")))

    # The linux-x86_64 platform's constraints key its configuration hash
    # (test 18 of run_tests.sh pins that hash): any change here re-keys every
    # action.
    if constraints("linux-x86_64") != ["prelude//os/constraints:linux", "prelude//cpu/constraints:x86_64"]:
        fail("platform table: the constraints of linux-x86_64 changed: {}".format(constraints("linux-x86_64")))
