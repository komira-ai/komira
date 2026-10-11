# =============================================================================
# src/kci_validate/tests/test_native_install.mojo -- the native install
#   checks (native_install.mojo) over environments written under TEST_TMPDIR.
# =============================================================================
#
# The fixture is what a library shipping native code installs, in the shape
# tools/build/package/pack/conda_lib.zig (#1363) packs: metadata.json
# `lib_files` rows `{kind, path, sha256}` for lib/libkomira_alpha_native.so.1
# (`shared`, mode 755), lib/libkomira_alpha_native.so (`link`, a symbolic
# link to it, the sha256 of the bytes it resolves to) and
# lib/libkomira_alpha_holder.a (`static`, mode 644), the run requirement
# `__glibc >=2.34`, and the conda-meta record listing those files. The
# `.so` is a minimal ELF this test writes: a dynamic section with NEEDED
# libc.so.6 and libkomira_crypto_native.so.1 (installed by another package,
# komira_crypto), DT_RUNPATH $ORIGIN, DT_FLAGS DF_SYMBOLIC.
#
# ROWS, each ONE change to the good environment, each refused by its finding:
#   (0) the good environment: four rows, all ok; a pin with no lib_files
#       adds no row;
#   (1) lib_files: a sha256 mismatch (the .so's bytes changed after
#       packing); a missing file (the holder archive); a mode 644 .so; a
#       dangling link; a link that is a regular file; an extra .so the
#       package's record lists and no row does; a libkomira_ file in lib/
#       no installed record lists; a row the record does not list;
#   (2) the rows among themselves: two shared rows, a link with no shared
#       row, a link at another name, a link recording another sha256, a
#       static row not lib<x>.a;
#   (3) glibc: `__glibc >=2.38` refused, `__glibc >=2.34` accepted;
#   (4) needed: a NEEDED not in the environment (libssl.so.3, which only
#       the host has); a NEEDED found in lib/ through a link to a file
#       outside the environment; a NEEDED with no RUNPATH $ORIGIN; a
#       RUNPATH entry /usr/lib; NEEDED on the JIT-only holder;
#   (5) symbolic: a .so without DF_SYMBOLIC; DT_SYMBOLIC alone passes;
#   (6) loaded-from: the record of a good run passes; a komira .so loaded
#       from /usr/lib and a codec (libzstd.so.1) from /lib are refused; a
#       record with no `calling init:` line is refused; `run_loaded_from`
#       runs the program through the runner with LD_DEBUG=libs and
#       LD_DEBUG_OUTPUT added to the cleared environment, and reads the
#       record the loader wrote;
#   (7) the ELF reader: NEEDED, SONAME, RUNPATH, FLAGS read back; not ELF,
#       truncated, no dynamic section refused.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs, remove, symlink
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import ResultValidationCheck
from kci_build import RunSpec, ScriptedRunner, ScriptedStep
from kci_release_set.conda_metadata import LibFile
from kci_release_set.member import file_sha256_hex
from kci_validate import (
    CHECK_GLIBC,
    CHECK_LIB_FILES,
    CHECK_NEEDED,
    CHECK_SYMBOLIC,
    InstallPin,
    check_native_install,
    lib_files_findings,
    lib_rows_findings,
    loaded_from_findings,
    needed_findings,
    read_dynamic,
    run_loaded_from,
    symbolic_findings,
)

comptime SO: String = "lib/libkomira_alpha_native.so.1"
comptime LINK: String = "lib/libkomira_alpha_native.so"
comptime HOLDER: String = "lib/libkomira_alpha_holder.a"
comptime CRYPTO: String = "lib/libkomira_crypto_native.so.1"
comptime GLIBC_OK: String = "__glibc >=2.34"


def _chmod(path: String, mode: Int32) raises:
    var p = path
    # SAFETY: `p` pins the NUL-terminated path across the synchronous call.
    var rc = external_call["chmod", Int32](p.as_c_string_slice().unsafe_ptr(), mode)
    if rc != 0:
        raise Error("test: chmod failed for '" + path + "'")


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/native_install_") + String(Int(external_call["getpid", Int32]())) + String("/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _put(mut b: List[UInt8], off: Int, v: Int, n: Int):
    for i in range(n):
        b[off + i] = UInt8((v >> (8 * i)) & 0xFF)


struct Dyn(Copyable, Movable):
    """What the test ELF's dynamic section says."""

    var needed: List[String]
    var runpath: String
    var flags: Int
    var symbolic_tag: Bool
    var soname: String

    def __init__(out self):
        self.needed = List[String]()
        self.needed.append(String("libc.so.6"))
        self.needed.append(String("libkomira_crypto_native.so.1"))
        self.runpath = String("$ORIGIN")
        self.flags = 0x2
        self.symbolic_tag = False
        self.soname = String("libkomira_alpha_native.so.1")


def _str_at(mut t: List[UInt8], s: String) -> Int:
    """Append `s` and a NUL to the string table `t`; where it starts."""
    var at = len(t)
    var b = s.as_bytes()
    for i in range(len(b)):
        t.append(b[i])
    t.append(0)
    return at


def _elf(d: Dyn) -> List[UInt8]:
    """A minimal 64-bit little-endian ELF shared object: the header, a
    dynamic string table, a dynamic section, three section headers."""
    var strtab = List[UInt8]()
    strtab.append(0)
    var tags = List[Int]()
    var vals = List[Int]()

    for i in range(len(d.needed)):
        tags.append(1)
        vals.append(_str_at(strtab, d.needed[i]))
    if d.soname.byte_length() > 0:
        tags.append(14)
        vals.append(_str_at(strtab, d.soname))
    if d.runpath.byte_length() > 0:
        tags.append(29)
        vals.append(_str_at(strtab, d.runpath))
    if d.symbolic_tag:
        tags.append(16)
        vals.append(0)
    if d.flags != 0:
        tags.append(30)
        vals.append(d.flags)
    tags.append(0)
    vals.append(0)
    var str_off = 64
    var dyn_off = (str_off + len(strtab) + 7) // 8 * 8
    var sh_off = dyn_off + 16 * len(tags)
    var b = List[UInt8]()
    for _ in range(sh_off + 3 * 64):
        b.append(0)
    b[0] = 0x7F
    b[1] = 0x45
    b[2] = 0x4C
    b[3] = 0x46
    b[4] = 2
    b[5] = 1
    b[6] = 1
    _put(b, 0x10, 3, 2)
    _put(b, 0x12, 0x3E, 2)
    _put(b, 0x14, 1, 4)
    _put(b, 0x28, sh_off, 8)
    _put(b, 0x34, 64, 2)
    _put(b, 0x3A, 64, 2)
    _put(b, 0x3C, 3, 2)
    for i in range(len(strtab)):
        b[str_off + i] = strtab[i]
    for i in range(len(tags)):
        _put(b, dyn_off + 16 * i, tags[i], 8)
        _put(b, dyn_off + 16 * i + 8, vals[i], 8)
    # [1] .dynstr (SHT_STRTAB), [2] .dynamic (SHT_DYNAMIC, sh_link 1)
    _put(b, sh_off + 64 + 4, 3, 4)
    _put(b, sh_off + 64 + 0x18, str_off, 8)
    _put(b, sh_off + 64 + 0x20, len(strtab), 8)
    _put(b, sh_off + 128 + 4, 6, 4)
    _put(b, sh_off + 128 + 0x18, dyn_off, 8)
    _put(b, sh_off + 128 + 0x20, 16 * len(tags), 8)
    _put(b, sh_off + 128 + 0x28, 1, 4)
    return b^


def _write_bytes(path: String, b: List[UInt8]) raises:
    var f = open(path, "w")
    f.write_bytes(b)
    f.close()


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def _row(kind: String, path: String, sha: String) -> LibFile:
    var f = LibFile()
    f.kind = kind.copy()
    f.path = path.copy()
    f.sha256_hex = sha.copy()
    return f^


def _record(env: String, name: String, files: List[String]) raises:
    var s = String('{"name":"') + name + String('","version":"1.0.0","build":"h0_1","files":[')
    for i in range(len(files)):
        if i > 0:
            s += String(",")
        s += String('"') + files[i] + String('"')
    _write(env + String("/conda-meta/") + name + String("-1.0.0-h0_1.json"), s + String("]}"))


def _alpha_files() -> List[String]:
    var f = List[String]()
    f.append(String(HOLDER))
    f.append(String(LINK))
    f.append(String(SO))
    f.append(String("lib/mojo/komira_alpha.mojoc"))
    f.append(String("share/doc/komira_alpha/README.md"))
    return f^


struct Env(Movable):
    var dir: String
    var pin: InstallPin

    def __init__(out self, sub: String, d: Dyn = Dyn()) raises:
        self.dir = _tmp(sub)
        makedirs(self.dir + String("/lib"), exist_ok=True)
        makedirs(self.dir + String("/conda-meta"), exist_ok=True)
        _write_bytes(self.dir + String("/") + String(SO), _elf(d))
        _chmod(self.dir + String("/") + String(SO), Int32(0o755))
        symlink(String("libkomira_alpha_native.so.1"), self.dir + String("/") + String(LINK))
        _write(self.dir + String("/") + String(HOLDER), String("!<arch>\n"))
        _chmod(self.dir + String("/") + String(HOLDER), Int32(0o644))
        _write_bytes(self.dir + String("/") + String(CRYPTO), _elf(Dyn()))
        _chmod(self.dir + String("/") + String(CRYPTO), Int32(0o755))
        _record(self.dir, String("komira_alpha"), _alpha_files())
        var crypto = List[String]()
        crypto.append(String(CRYPTO))
        crypto.append(String("lib/libkomira_crypto_native.so"))
        _record(self.dir, String("komira_crypto"), crypto)
        var so_sha = file_sha256_hex(self.dir + String("/") + String(SO))
        self.pin = InstallPin(String("komira_alpha"))
        self.pin.version = String("1.0.0")
        self.pin.build = String("h0_1")
        self.pin.subdir = String("linux-64")
        self.pin.is_library = True
        self.pin.has_lib_files = True
        self.pin.lib_files.append(_row(String("static"), String(HOLDER), file_sha256_hex(self.dir + String("/") + String(HOLDER))))
        self.pin.lib_files.append(_row(String("link"), String(LINK), so_sha))
        self.pin.lib_files.append(_row(String("shared"), String(SO), so_sha))
        self.pin.depends.append(String("__linux"))
        self.pin.depends.append(String(GLIBC_OK))
        self.pin.depends.append(String("mojo-compiler ==1.0.0"))

    def path(self, rel: String) -> String:
        return self.dir + String("/") + rel


def _pins(e: Env) -> List[InstallPin]:
    var p = List[InstallPin]()
    p.append(e.pin.copy())
    return p^


def _joined(xs: List[String]) -> String:
    return String(" | ").join(xs)


def _has(xs: List[String], want: String) raises:
    for i in range(len(xs)):
        if xs[i] == want:
            return
    assert_true(False, String("no finding '") + want + String("' in: ") + _joined(xs))


def test_the_good_environment_passes_every_row() raises:
    var e = Env(String("good"))
    var checks = List[ResultValidationCheck]()
    var ok = check_native_install(e.dir, _pins(e), checks)
    var said = String("")
    for i in range(len(checks)):
        said += checks[i].got + String(" | ")
    assert_true(ok, said)
    assert_equal(len(checks), 4)
    assert_equal(checks[0].check, String(CHECK_LIB_FILES))
    assert_equal(checks[1].check, String(CHECK_GLIBC))
    assert_equal(checks[2].check, String(CHECK_NEEDED))
    assert_equal(checks[3].check, String(CHECK_SYMBOLIC))
    for i in range(len(checks)):
        assert_true(checks[i].ok, checks[i].got)
        assert_equal(checks[i].got, checks[i].check + String(": komira_alpha ok"))
    # a pin with no lib_files (a package with no native file) adds no row
    var plain = e.pin.copy()
    plain.has_lib_files = False
    plain.lib_files = List[LibFile]()
    var none = List[InstallPin]()
    none.append(plain^)
    var c2 = List[ResultValidationCheck]()
    assert_true(check_native_install(e.dir, none, c2))
    assert_equal(len(c2), 0)


def test_a_sha256_mismatch_is_refused() raises:
    var e = Env(String("sha"))
    var d = Dyn()
    d.soname = String("libkomira_alpha_native.so.2")
    _write_bytes(e.path(String(SO)), _elf(d))
    var got = file_sha256_hex(e.path(String(SO)))
    var f = lib_files_findings(e.dir, e.pin)
    _has(f, String(SO) + String(" has sha256 ") + got + String(", its lib_files row records ") + e.pin.lib_files[2].sha256_hex)
    _has(
        f, String(LINK) + String(" resolves to bytes of sha256 ") + got + String(", its lib_files row records ")
        + e.pin.lib_files[1].sha256_hex,
    )
    var checks = List[ResultValidationCheck]()
    assert_false(check_native_install(e.dir, _pins(e), checks))
    assert_false(checks[0].ok)
    assert_true(checks[0].got.startswith(String("lib_files: komira_alpha: ")), checks[0].got)


def test_a_missing_file_is_refused() raises:
    var e = Env(String("missing"))
    remove(e.path(String(HOLDER)))
    var f = lib_files_findings(e.dir, e.pin)
    assert_equal(len(f), 1, _joined(f))
    _has(f, String(HOLDER) + String(" is missing: its lib_files row lists it and the environment has no such file"))


def test_a_mode_644_shared_library_is_refused() raises:
    var e = Env(String("mode"))
    _chmod(e.path(String(SO)), Int32(0o644))
    var f = lib_files_findings(e.dir, e.pin)
    assert_equal(len(f), 1, _joined(f))
    _has(f, String(SO) + String(" has mode 644, must be 755 (a shared row)"))
    # and a static archive at 755
    var e2 = Env(String("mode_static"))
    _chmod(e2.path(String(HOLDER)), Int32(0o755))
    _has(lib_files_findings(e2.dir, e2.pin), String(HOLDER) + String(" has mode 755, must be 644 (a static row)"))


def test_a_dangling_link_is_refused() raises:
    var e = Env(String("dangling"))
    remove(e.path(String(LINK)))
    symlink(String("libkomira_alpha_native.so.2"), e.path(String(LINK)))
    var f = lib_files_findings(e.dir, e.pin)
    assert_equal(len(f), 1, _joined(f))
    _has(f, String(LINK) + String(" is a dangling symbolic link: it resolves to no file"))


def test_a_link_that_is_a_regular_file_or_points_elsewhere_is_refused() raises:
    var e = Env(String("notlink"))
    remove(e.path(String(LINK)))
    _write_bytes(e.path(String(LINK)), _elf(Dyn()))
    _has(lib_files_findings(e.dir, e.pin), String(LINK) + String(" is not a symbolic link; its row is a link"))
    var e2 = Env(String("elsewhere"))
    remove(e2.path(String(LINK)))
    symlink(String("libkomira_crypto_native.so.1"), e2.path(String(LINK)))
    var f = lib_files_findings(e2.dir, e2.pin)
    assert_equal(len(f), 1, _joined(f))
    assert_true(f[0].find(String(" resolves to ")) > 0 and f[0].find(String(", not the shared row's file ")) > 0, f[0])


def test_an_extra_file_is_refused() raises:
    # the package installs a .so its lib_files rows do not name
    var e = Env(String("extra"))
    _write_bytes(e.path(String("lib/libkomira_alpha_extra.so.1")), _elf(Dyn()))
    var files = _alpha_files()
    files.append(String("lib/libkomira_alpha_extra.so.1"))
    _record(e.dir, String("komira_alpha"), files)
    var f = lib_files_findings(e.dir, e.pin)
    assert_equal(len(f), 1, _joined(f))
    _has(f, String("lib/libkomira_alpha_extra.so.1 is installed by komira_alpha and is not one of its lib_files rows"))
    # a komira file in lib/ that no installed package lists
    var e2 = Env(String("stray"))
    _write_bytes(e2.path(String("lib/libkomira_stray.so.1")), _elf(Dyn()))
    var f2 = lib_files_findings(e2.dir, e2.pin)
    assert_equal(len(f2), 1, _joined(f2))
    _has(f2, String("lib/libkomira_stray.so.1 is in the environment and no installed package lists it"))
    # a row the installed record does not list
    var e3 = Env(String("unlisted"))
    var only = List[String]()
    only.append(String(SO))
    only.append(String(LINK))
    _record(e3.dir, String("komira_alpha"), only)
    _has(
        lib_files_findings(e3.dir, e3.pin),
        String(HOLDER) + String(" is a lib_files row the installed record of komira_alpha does not list"),
    )


def test_rows_that_disagree_with_each_other_are_refused() raises:
    var sha = String("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    var other = String("fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
    var rows = List[LibFile]()
    rows.append(_row(String("shared"), String(SO), sha))
    rows.append(_row(String("shared"), String("lib/libkomira_beta_native.so.1"), sha))
    rows.append(_row(String("link"), String(LINK), sha))
    _has(lib_rows_findings(rows), String("2 shared rows; a library ships one shared library"))
    rows = List[LibFile]()
    rows.append(_row(String("link"), String(LINK), sha))
    _has(lib_rows_findings(rows), String("a link row (lib/libkomira_alpha_native.so) with no shared row to link to"))
    rows = List[LibFile]()
    rows.append(_row(String("shared"), String(SO), sha))
    rows.append(_row(String("link"), String("lib/libkomira_other.so"), sha))
    _has(
        lib_rows_findings(rows),
        String("the link row is lib/libkomira_other.so, not lib/libkomira_alpha_native.so, the link name of ") + String(SO),
    )
    rows = List[LibFile]()
    rows.append(_row(String("shared"), String(SO), sha))
    rows.append(_row(String("link"), String(LINK), other))
    _has(
        lib_rows_findings(rows),
        String("the link row ") + String(LINK) + String(" records sha256 ") + other + String(", not its target's ") + sha,
    )
    rows = List[LibFile]()
    rows.append(_row(String("shared"), String(SO), sha))
    _has(
        lib_rows_findings(rows),
        String("the shared row ") + String(SO) + String(" has 0 link rows; it must have one, ") + String(LINK),
    )
    rows = List[LibFile]()
    rows.append(_row(String("static"), String("lib/holder.so"), sha))
    _has(lib_rows_findings(rows), String("row lib/holder.so is static and not lib/lib<name>.a"))
    rows = List[LibFile]()
    rows.append(_row(String("shared"), String("lib/libkomira_x.so"), sha))
    _has(lib_rows_findings(rows), String("row lib/libkomira_x.so is shared and not lib/lib<name>.so.<number>"))


def test_a_glibc_floor_of_2_38_is_refused() raises:
    var e = Env(String("glibc"))
    e.pin.depends[1] = String("__glibc >=2.38")
    var checks = List[ResultValidationCheck]()
    assert_false(check_native_install(e.dir, _pins(e), checks))
    assert_true(checks[0].ok, checks[0].got)
    assert_false(checks[1].ok)
    assert_equal(
        checks[1].got,
        String(
            "glibc: komira_alpha: requires '__glibc >=2.38', not the platform floor '__glibc >=2.34'"
            " (tools/build/platforms/table.bzl os_floor)"
        ),
    )
    assert_equal(checks[1].expected, String("requires exactly __glibc >=2.34"))


def test_needed_outside_the_environment_is_refused() raises:
    var d = Dyn()
    d.needed.append(String("libssl.so.3"))
    var e = Env(String("needed_ssl"), d)
    var f = needed_findings(e.dir, e.pin)
    assert_equal(len(f), 1, _joined(f))
    _has(
        f,
        String(SO) + String(" has NEEDED libssl.so.3, which is not in the environment's lib/: it would resolve")
        + String(" outside the environment, or not at all"),
    )
    # found in lib/, but through a link to a file outside the environment
    var d2 = Dyn()
    d2.needed.append(String("libzstd.so.1"))
    var e2 = Env(String("needed_link"), d2)
    var outside = _tmp(String("outside"))
    _write(outside + String("/libzstd.so.1"), String("not ours"))
    symlink(outside + String("/libzstd.so.1"), e2.path(String("lib/libzstd.so.1")))
    var f2 = needed_findings(e2.dir, e2.pin)
    assert_equal(len(f2), 1, _joined(f2))
    assert_true(f2[0].find(String("has NEEDED libzstd.so.1, whose lib/ entry resolves to ")) > 0, f2[0])
    assert_true(f2[0].endswith(String(", outside the environment")), f2[0])
    # inside the environment it resolves
    var e3 = Env(String("needed_in"), d2)
    _write(e3.path(String("lib/libzstd.so.1")), String("codec"))
    var f3 = needed_findings(e3.dir, e3.pin)
    assert_equal(len(f3), 0, _joined(f3))


def test_needed_without_origin_or_with_another_runpath_is_refused() raises:
    var d = Dyn()
    d.runpath = String("")
    var e = Env(String("no_origin"), d)
    _has(
        needed_findings(e.dir, e.pin),
        String(SO) + String(" has NEEDED libkomira_crypto_native.so.1 and no DT_RUNPATH $ORIGIN: with")
        + String(" LD_LIBRARY_PATH unset the loader would search only the system's directories, outside the environment"),
    )
    var d2 = Dyn()
    d2.runpath = String("$ORIGIN:/usr/lib")
    var e2 = Env(String("usr_lib"), d2)
    var f2 = needed_findings(e2.dir, e2.pin)
    assert_equal(len(f2), 1, _joined(f2))
    _has(f2, String(SO) + String(" has DT_RUNPATH entry '/usr/lib', which searches outside the environment"))
    # a .so needing only glibc needs no RUNPATH
    var d3 = Dyn()
    d3.needed = List[String]()
    d3.needed.append(String("libc.so.6"))
    d3.runpath = String("")
    var e3 = Env(String("glibc_only"), d3)
    assert_equal(len(needed_findings(e3.dir, e3.pin)), 0)


def test_needed_on_the_jit_holder_is_refused() raises:
    var d = Dyn()
    d.needed.append(String("libkomira_log_holder_jit.so.1"))
    var e = Env(String("jit"), d)
    _has(
        needed_findings(e.dir, e.pin),
        String(SO) + String(" has NEEDED libkomira_log_holder_jit.so.1, the JIT-only holder no installed .so may need"),
    )


def test_a_shared_library_without_df_symbolic_is_refused() raises:
    var d = Dyn()
    d.flags = 0
    var e = Env(String("symbolic"), d)
    var f = symbolic_findings(e.dir, e.pin)
    assert_equal(len(f), 1)
    assert_equal(f[0], String(SO) + String(" has no DF_SYMBOLIC in DT_FLAGS: it was linked without -Bsymbolic"))
    var checks = List[ResultValidationCheck]()
    assert_false(check_native_install(e.dir, _pins(e), checks))
    assert_false(checks[3].ok)
    # the older DT_SYMBOLIC tag says the same
    var d2 = Dyn()
    d2.flags = 0
    d2.symbolic_tag = True
    var e2 = Env(String("symbolic_tag"), d2)
    assert_equal(len(symbolic_findings(e2.dir, e2.pin)), 0)


def _trace(env: String, komira_dir: String, codec_dir: String) -> String:
    return (
        String("     41:\tfind library=libkomira_alpha_native.so.1 [0]; searching\n")
        + String("     41:\t\n")
        + String("     41:\tcalling init: /lib/x86_64-linux-gnu/libc.so.6\n")
        + String("     41:\tcalling init: ") + codec_dir + String("/libzstd.so.1\n")
        + String("     41:\tcalling init: ") + komira_dir + String("/libkomira_alpha_native.so.1\n")
        + String("     41:\tcalling init: ") + env + String("/lib/libkomira_crypto_native.so.1\n")
    )


def test_the_loaded_from_row() raises:
    var e = Env(String("loaded"))
    var lib = e.dir + String("/lib")
    var f = loaded_from_findings(_trace(e.dir, lib, lib), e.dir)
    assert_equal(len(f), 0, _joined(f))
    var f2 = loaded_from_findings(_trace(e.dir, String("/usr/lib"), lib), e.dir)
    assert_equal(len(f2), 1, _joined(f2))
    _has(f2, String("libkomira_alpha_native.so.1 was loaded from /usr/lib/libkomira_alpha_native.so.1, not from ") + lib + String("/"))
    var f3 = loaded_from_findings(_trace(e.dir, lib, String("/lib/x86_64-linux-gnu")), e.dir)
    assert_equal(len(f3), 1, _joined(f3))
    _has(f3, String("libzstd.so.1 was loaded from /lib/x86_64-linux-gnu/libzstd.so.1, not from ") + lib + String("/"))
    _has(
        loaded_from_findings(String("     41:\tfind library=libc.so.6 [0]; searching\n"), e.dir),
        String("the loader's record holds no 'calling init:' line: LD_DEBUG=libs was not honoured, so it shows nothing"),
    )


def test_run_loaded_from_runs_the_program_with_the_loader_record_on() raises:
    var e = Env(String("run_loaded"))
    var out = _tmp(String("run_loaded_out"))
    var prefix = out + String("/ld")
    var argv = List[String]()
    argv.append(String("run"))
    argv.append(String("readme_komira_alpha.mojo"))
    var lib = e.dir + String("/lib")
    var runner = ScriptedRunner()
    var step = ScriptedStep(argv.copy())
    step.writes(prefix + String(".4242"), _trace(e.dir, String("/usr/lib"), lib))
    runner.expect(step^)
    var spec = RunSpec(String("/bin/pixi"), argv.copy(), out.copy(), 60, out + String("/o"), out + String("/e"))
    var env = List[String]()
    env.append(String("PATH=/usr/bin"))
    var f = run_loaded_from(runner, spec^, env, prefix, e.dir)
    assert_equal(runner.remaining(), 0)
    var got = runner.calls[0].env.value().copy()
    assert_equal(len(got), 3)
    assert_equal(got[0], String("PATH=/usr/bin"))
    assert_equal(got[1], String("LD_DEBUG=libs"))
    assert_equal(got[2], String("LD_DEBUG_OUTPUT=") + prefix)
    assert_equal(len(f), 1, _joined(f))
    assert_true(f[0].startswith(String("libkomira_alpha_native.so.1 was loaded from /usr/lib/")), f[0])
    # a program that failed says nothing about where it loaded from
    var r2 = ScriptedRunner()
    r2.expect(ScriptedStep(argv.copy(), Int32(1)))
    var spec2 = RunSpec(String("/bin/pixi"), argv.copy(), out.copy(), 60, out + String("/o"), out + String("/e"))
    var raised = False
    try:
        _ = run_loaded_from(r2, spec2^, env, prefix, e.dir)
    except err:
        raised = True
        assert_true(String(err).endswith(String(" did not pass: exit 1")), String(err))
    assert_true(raised)


def test_the_elf_reader() raises:
    var d = Dyn()
    d.runpath = String("$ORIGIN:/opt/x")
    d.flags = 0x2 | 0x8
    var got = read_dynamic(_elf(d), String("x.so"))
    assert_equal(len(got.needed), 2)
    assert_equal(got.needed[0], String("libc.so.6"))
    assert_equal(got.needed[1], String("libkomira_crypto_native.so.1"))
    assert_equal(got.soname, String("libkomira_alpha_native.so.1"))
    assert_equal(len(got.runpath), 2)
    assert_equal(got.runpath[1], String("/opt/x"))
    assert_equal(got.flags, 0xA)
    assert_true(got.has_df_symbolic())
    var bad = List[UInt8]()
    var arch = String("!<arch>\n").as_bytes()
    for i in range(len(arch)):
        bad.append(arch[i])
    for _ in range(80):
        bad.append(0)
    try:
        _ = read_dynamic(bad, String("x.a"))
        assert_true(False, "an archive was read as ELF")
    except err:
        assert_equal(String(err), String("x.a: not a 64-bit little-endian ELF file"))
    var cut = _elf(Dyn())
    var short = List[UInt8]()
    for i in range(len(cut) - 64):
        short.append(cut[i])
    try:
        _ = read_dynamic(short, String("cut.so"))
        assert_true(False, "a truncated file was read")
    except err:
        assert_equal(String(err), String("cut.so: ELF: a header or table points past the end of the file"))
    var nodyn = _elf(Dyn())
    _put(nodyn, len(nodyn) - 64 + 4, 1, 4)
    try:
        _ = read_dynamic(nodyn, String("obj.o"))
        assert_true(False, "a file with no dynamic section was read")
    except err:
        assert_equal(String(err), String("obj.o: ELF: no dynamic section (not a shared object)"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
