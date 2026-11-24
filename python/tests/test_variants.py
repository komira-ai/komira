"""The variant selector: from a directory with a VARIANTS manifest, the loader
opens the highest CPU level whose features every processor of /proc/cpuinfo
lists, falls back to a lower level only when the CPU lacks a feature of the
higher one, refuses a CPU below the lowest with UnsupportedCpuError, and
refuses a damaged directory with LibraryLoadError instead of loading another
level (docs/design/isa_variants.md, decision 5).

    test_variants.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/isa_variants/` holds the fixtures of python/tests/fixtures/isa_variants
(its README says what each is) and `VARIANTS_shipped`, the manifest the build
writes from the linux-x86_64 row; `<dir>/cpuinfo_x86_64_v3.txt` is the CPU
test's x86-64-v3 cpuinfo; `<dir>/fake_v1_3/libkomira.so` and
`<dir>/fake_v2/libkomira.so` are stand-ins of fake_libkomira.c (ABI 1.3, which
loads, and 2.0, which is refused once opened). `--runtime-dir` is not read.
The directories the cases need are written into the test's temporary
directory. A process holds one library, so the cases that load come last.
"""

import ctypes
import os
import pathlib
import shutil
import sys
import tempfile

from komira import LibraryLoadError, UnsupportedCpuError
from komira import _native, _runtime


def refused(call, cls):
    """The message of the `cls` (exactly that class) `call` raises."""
    try:
        call()
    except LibraryLoadError as e:
        assert type(e) is cls, repr(e)
        assert e.status is None, e.status
        return str(e)
    raise AssertionError("nothing was refused")


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    fixtures = os.path.join(lib_dir, "isa_variants")
    scratch = tempfile.mkdtemp()

    def fixture(name):
        if name == "cpuinfo_x86_64_v3.txt":
            return os.path.join(lib_dir, name)
        return os.path.join(fixtures, name)

    def read(path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def write(path, content, mode="w"):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode) as f:
            f.write(content)
        return path

    def planted_dir(name, manifest, files=None):
        """A directory `name` with `manifest` as its VARIANTS and an empty file
        at each path a line names, except where `files` lists the paths to
        create instead."""
        d = os.path.join(scratch, name)
        write(os.path.join(d, "VARIANTS"), manifest, "wb" if isinstance(manifest, bytes) else "w")
        if files is None:
            text = manifest.decode("utf-8") if isinstance(manifest, bytes) else manifest
            files = [line.split("\t")[1] for line in text.splitlines()]
        for rel in files:
            write(os.path.join(d, rel), "")
        return d

    def without(content, drop, processor=None, key="flags"):
        """`content` with the words `drop` taken off the `key` line of every
        processor, or only of the `processor`-th one (from 0)."""
        out, seen = [], -1
        for line in content.split("\n"):
            name, _, value = line.partition(":")
            if name.strip() == key:
                seen += 1
                if processor is None or processor == seen:
                    line = name + ": " + " ".join(f for f in value.split() if f not in drop)
            out.append(line)
        return "\n".join(out)

    def x86(directory, cpuinfo):
        return _native._select_variant(directory, cpuinfo, system="linux", machine="x86_64")

    def unsupported(directory, floor, missing, cpuinfo, key="flags"):
        return (
            "this CPU runs no variant of libkomira in {}: the lowest, {}, needs {}, which the `{}` lines of {} "
            "do not all list".format(directory, floor, ", ".join(missing), key, cpuinfo)
        )

    manifests = {
        name: read(os.path.join(fixtures, "VARIANTS_" + name))
        for name in ("shipped", "x86_64_v4", "aarch64", "macos")
    }
    dirs = {name: planted_dir("m_" + name, text) for name, text in manifests.items()}
    # The table's manifest column names a fixture file; `shipped` is the row's.
    dirs["VARIANTS_x86_64_v4"], dirs["VARIANTS_aarch64"], dirs["VARIANTS_macos"] = (
        dirs["x86_64_v4"],
        dirs["aarch64"],
        dirs["macos"],
    )

    def lines(name):
        return [line.split("\t") for line in manifests[name].splitlines()]

    # The shipped manifest is the linux-x86_64 row's: the floor, x86-64-v2, at
    # the plain path that a reader knowing nothing of variants opens, and
    # x86-64-v3, the build the tests run, above it. Its features are the ones
    # the single library's check holds, so the level of that library ships.
    shipped = lines("shipped")
    assert [line[:2] for line in shipped] == [
        ["x86-64-v2", "libkomira.so"],
        ["x86-64-v3", "variants/x86-64-v3/libkomira.so"],
    ], shipped
    assert sorted(shipped[1][2].split()) == sorted(_native._X86_64_V3_FLAGS), shipped[1][2]
    v3_only = sorted(set(shipped[1][2].split()) - set(shipped[0][2].split()))
    assert v3_only == ["abm", "avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "movbe"], v3_only

    # ---- The table of expected choices ---------------------------------------
    # Each CPU at each level picks that level; a v4 CPU where v4 is not shipped
    # picks v3; a CPU below the floor is refused naming the floor's missing
    # features in the manifest's order; arm64 reads `Features`, x86 `flags`;
    # a manifest without features reads no cpuinfo at all.
    rows = [line.split("\t") for line in read(os.path.join(fixtures, "choices.tsv")).splitlines()]
    assert rows[0] == ["cpuinfo", "system", "machine", "manifest", "choice"], rows[0]
    assert len(rows) > 1
    for cpuinfo_name, system, machine, manifest, choice in rows[1:]:
        directory = dirs[manifest]
        names = {os.path.join(directory, line[1]): line[0] for line in lines(manifest.replace("VARIANTS_", ""))}
        cpuinfo = os.path.join(scratch, "no_such_cpuinfo") if cpuinfo_name == "-" else fixture(cpuinfo_name)

        def pick():
            return _native._select_variant(directory, cpuinfo, system=system, machine=machine)

        if choice.startswith("refused "):
            first = lines(manifest.replace("VARIANTS_", ""))[0][0]
            key = _native._FEATURE_KEYS[machine]
            want = unsupported(directory, first, choice.split()[1:], cpuinfo, key)
            assert refused(pick, UnsupportedCpuError) == want, (cpuinfo_name, manifest)
        else:
            got = pick()
            assert names.get(got) == choice, (cpuinfo_name, manifest, got, choice)

    # ---- Falling back from the x86-64-v3 CPU -------------------------------
    v3_text = read(fixture("cpuinfo_x86_64_v3.txt"))
    shipped_dir = dirs["shipped"]
    floor = os.path.join(shipped_dir, "libkomira.so")
    v3_file = os.path.join(shipped_dir, "variants", "x86-64-v3", "libkomira.so")
    assert x86(shipped_dir, fixture("cpuinfo_x86_64_v3.txt")) == v3_file

    # Without any one feature only x86-64-v3 needs, the CPU gets x86-64-v2.
    for flag in v3_only:
        one = write(os.path.join(scratch, "v3_without_" + flag), without(v3_text, {flag}))
        assert x86(shipped_dir, one) == floor, flag
    # A feature counts only when every processor lists it: with avx2 on the
    # first processor and not the second, the CPU gets x86-64-v2.
    second = write(os.path.join(scratch, "avx2_on_one"), without(v3_text, {"avx2"}, processor=1))
    assert x86(shipped_dir, second) == floor
    # Only the `flags` key counts: avx2 on the `vmx flags` line alone does not.
    vmx = without(v3_text, {"avx2"}).replace("vmx flags\t: ", "vmx flags\t: avx2 ")
    assert "vmx flags\t: avx2 " in vmx
    vmx = write(os.path.join(scratch, "avx2_on_vmx"), vmx)
    assert x86(shipped_dir, vmx) == floor
    # A feature is a whole word: avx512f does not give avx2.
    word = write(os.path.join(scratch, "avx2_as_part"), without(v3_text, {"avx2"}).replace(" avx ", " avx avx2x "))
    assert x86(shipped_dir, word) == floor
    # Without a floor feature too, the CPU is refused, naming only the floor's
    # missing ones (not avx2, which only x86-64-v3 needs).
    low = write(os.path.join(scratch, "no_popcnt"), without(v3_text, {"popcnt", "avx2"}))
    assert refused(lambda: x86(shipped_dir, low), UnsupportedCpuError) == unsupported(
        shipped_dir, "x86-64-v2", ["popcnt"], low
    )
    # On arm64, the neoverse-n1 CPU without `atomics` on one processor gets
    # `generic`, and without `fp` it is refused.
    n1_text = read(fixture("cpuinfo_aarch64_neoverse_n1.txt"))
    arm_dir = dirs["aarch64"]
    no_atomics = write(
        os.path.join(scratch, "n1_without_atomics"), without(n1_text, {"atomics"}, processor=2, key="Features")
    )
    got = _native._select_variant(arm_dir, no_atomics, system="linux", machine="aarch64")
    assert got == os.path.join(arm_dir, "libkomira.so"), got
    no_fp = write(os.path.join(scratch, "n1_without_fp"), without(n1_text, {"fp"}, key="Features"))
    got = refused(lambda: _native._select_variant(arm_dir, no_fp, system="linux", machine="aarch64"), UnsupportedCpuError)
    assert got == unsupported(arm_dir, "generic", ["fp"], no_fp, "Features"), got

    # ---- The manifest's own shape --------------------------------------------
    # The last line the CPU satisfies wins, whatever is between: a manifest is
    # read as written, not re-sorted.
    order = planted_dir("order", "low\tlow.so\t\nhigh\thigh.so\tavx2\n")
    assert x86(order, fixture("cpuinfo_x86_64_v3.txt")) == os.path.join(order, "high.so")
    # A field after the third is ignored, so the manifest can grow.
    extra = planted_dir("extra", "x86-64-v2\tlibkomira.so\tpni\tsize=1\tmore\n")
    assert x86(extra, fixture("cpuinfo_x86_64_v3.txt")) == os.path.join(extra, "libkomira.so")
    # A last line without a newline is a line.
    no_newline = planted_dir("no_newline", "x86-64-v2\tlibkomira.so\tpni\nx86-64-v3\tv3.so\tavx2")
    assert x86(no_newline, fixture("cpuinfo_x86_64_v3.txt")) == os.path.join(no_newline, "v3.so")
    # A directory may be an os.PathLike, and so may the cpuinfo.
    got = _native._select_variant(
        pathlib.Path(shipped_dir), pathlib.Path(fixture("cpuinfo_x86_64_v3.txt")), system="linux", machine="x86_64"
    )
    assert got == v3_file, got
    # A relative directory is made absolute.
    here = os.getcwd()
    os.chdir(shipped_dir)
    try:
        want = os.path.join(os.getcwd(), "variants", "x86-64-v3", "libkomira.so")
        assert x86(".", fixture("cpuinfo_x86_64_v3.txt")) == want
    finally:
        os.chdir(here)

    # With no line listing features nothing is read: the cpuinfo does not
    # exist, and on Linux, macOS or a machine with no feature key the one line
    # is picked.
    gone = os.path.join(scratch, "no_such_cpuinfo")
    for system, machine in [("darwin", "arm64"), ("linux", "x86_64"), ("linux", "riscv64")]:
        got = _native._select_variant(dirs["macos"], gone, system=system, machine=machine)
        assert got == os.path.join(dirs["macos"], "libkomira.dylib"), (system, machine, got)

    # ---- Refusals: each names what is wrong, and none loads another level ----
    # A cpuinfo that cannot be read is a LibraryLoadError, not a claim about
    # the CPU and not a pick of the floor.
    want = (
        "cannot read the CPU features from {0}, so it is not known which variant of libkomira in {1} this CPU "
        "runs: [Errno 2] No such file or directory: '{0}'".format(gone, shipped_dir)
    )
    assert refused(lambda: x86(shipped_dir, gone), LibraryLoadError) == want

    # Features are read only on Linux x86_64 and aarch64.
    for system, machine in [("darwin", "arm64"), ("darwin", "x86_64"), ("linux", "riscv64"), ("win32", "AMD64")]:
        got = refused(
            lambda: _native._select_variant(shipped_dir, fixture("cpuinfo_x86_64_v3.txt"), system=system, machine=machine),
            LibraryLoadError,
        )
        want = (
            "the variant manifest {} lists CPU features, which are read from /proc/cpuinfo only on Linux x86_64 "
            "and aarch64, and this is {} {}".format(os.path.join(shipped_dir, "VARIANTS"), system, machine)
        )
        assert got == want, got

    # A missing manifest names the file.
    bare = os.path.join(scratch, "bare")
    os.makedirs(bare)
    want = "cannot read the variant manifest {0}: [Errno 2] No such file or directory: '{0}'".format(
        os.path.join(bare, "VARIANTS")
    )
    assert refused(lambda: x86(bare, fixture("cpuinfo_x86_64_v3.txt")), LibraryLoadError) == want

    def manifest_refusal(name, manifest):
        d = planted_dir(name, manifest, files=[])
        return d, refused(lambda: x86(d, fixture("cpuinfo_x86_64_v3.txt")), LibraryLoadError)

    # A manifest that is not UTF-8.
    d, got = manifest_refusal("latin1", b"x86-64-v2\tlibkomira.so\tpni \xff\n")
    want = (
        "the variant manifest {} is not UTF-8: 'utf-8' codec can't decode byte 0xff in position 27: "
        "invalid start byte".format(os.path.join(d, "VARIANTS"))
    )
    assert got == want, got
    # An empty manifest names no variant.
    d, got = manifest_refusal("empty", "")
    assert got == "the variant manifest {} names no variant".format(os.path.join(d, "VARIANTS")), got

    # A line with fewer than three fields, an empty name or an empty path, and
    # a blank line between two good ones, each name the line.
    def shape(number, d, line):
        return "line {} of the variant manifest {} is not `<name><TAB><path><TAB><features>`: {!r}".format(
            number, os.path.join(d, "VARIANTS"), line
        )

    for name, text, number, line in [
        ("two_fields", "x86-64-v2\tlibkomira.so\n", 1, "x86-64-v2\tlibkomira.so"),
        ("spaces", "x86-64-v2 libkomira.so pni\n", 1, "x86-64-v2 libkomira.so pni"),
        ("no_name", "\tlibkomira.so\tpni\n", 1, "\tlibkomira.so\tpni"),
        ("no_path", "x86-64-v2\t\tpni\n", 1, "x86-64-v2\t\tpni"),
        ("blank", "x86-64-v2\tlibkomira.so\tpni\n\nx86-64-v3\tv3.so\tavx2\n", 2, ""),
        ("newline", "\n", 1, ""),
        ("second", "x86-64-v2\tlibkomira.so\tpni\nx86-64-v3\n", 2, "x86-64-v3"),
    ]:
        d, got = manifest_refusal(name, text)
        assert got == shape(number, d, line), (name, got)

    # A path outside the directory, absolute or through `..`.
    for name, rel in [("absolute", "/lib/libkomira.so"), ("dotdot", "variants/../../libkomira.so"), ("up", "..")]:
        d, got = manifest_refusal(name, "x86-64-v2\tlibkomira.so\tpni\nx86-64-v3\t{}\tavx2\n".format(rel))
        want = "line 2 of the variant manifest {} names {!r}, which is not a path inside its directory".format(
            os.path.join(d, "VARIANTS"), rel
        )
        assert got == want, (name, got)

    # The picked file missing is refused, naming it; the floor beside it is not
    # loaded in its place. A missing file of a level the CPU does not run is
    # not looked at.
    no_v3 = planted_dir("no_v3", manifests["shipped"], files=["libkomira.so"])
    want = (
        "the variant manifest {} names {} for x86-64-v3, the variant this CPU runs, and there is no such file; "
        "no lower variant is loaded in its place".format(
            os.path.join(no_v3, "VARIANTS"), os.path.join(no_v3, "variants", "x86-64-v3", "libkomira.so")
        )
    )
    assert refused(lambda: x86(no_v3, fixture("cpuinfo_x86_64_v3.txt")), LibraryLoadError) == want
    assert x86(no_v3, fixture("cpuinfo_x86_64_westmere.txt")) == os.path.join(no_v3, "libkomira.so")
    # A directory at the picked path is not a library file either.
    dir_v3 = planted_dir("dir_v3", manifests["shipped"], files=["libkomira.so", "variants/x86-64-v3/libkomira.so/x"])
    got = refused(lambda: x86(dir_v3, fixture("cpuinfo_x86_64_v3.txt")), LibraryLoadError)
    assert got.startswith("the variant manifest {} names ".format(os.path.join(dir_v3, "VARIANTS"))), got

    # ---- Through load --------------------------------------------------------
    # The x86-64-v2 file is the ABI 2.0 stand-in, which the loader refuses once
    # it has opened it, and the x86-64-v3 file the ABI 1.3 one, which loads.
    # Every file the dynamic loader is handed is recorded.
    native_dir = os.path.join(scratch, "native")
    write(os.path.join(native_dir, "VARIANTS"), manifests["shipped"])
    os.makedirs(os.path.join(native_dir, "variants", "x86-64-v3"))
    shutil.copyfile(os.path.join(lib_dir, "fake_v2", "libkomira.so"), os.path.join(native_dir, "libkomira.so"))
    native_v3 = os.path.join(native_dir, "variants", "x86-64-v3", "libkomira.so")
    shutil.copyfile(os.path.join(lib_dir, "fake_v1_3", "libkomira.so"), native_v3)

    select = _native._select_variant
    check_cpu = _native._check_cpu
    check_runtime = _runtime.check_loaded_runtime
    cdll = ctypes.CDLL
    cpuinfo = [None]
    calls = []

    def selecting(directory):
        calls.append(("select", directory))
        return select(directory, cpuinfo[0], system="linux", machine="x86_64")

    def no_cpu_check():
        raise AssertionError("a directory with a manifest does not run the single library's CPU check")

    def runtime(directory):
        calls.append(("runtime", directory))

    def recording_cdll(path, *a, **k):
        calls.append(("open", path))
        return cdll(path, *a, **k)

    _native._select_variant = selecting
    _native._check_cpu = no_cpu_check
    _runtime.check_loaded_runtime = runtime
    ctypes.CDLL = recording_cdll
    try:
        # A CPU below the floor: refused before anything is opened.
        cpuinfo[0] = fixture("cpuinfo_x86_64_core2.txt")
        got = refused(lambda: _native.load(native_dir), UnsupportedCpuError)
        assert got == unsupported(native_dir, "x86-64-v2", ["popcnt", "sse4_2"], cpuinfo[0]), got
        assert calls == [("select", native_dir)], calls
        assert _native._loaded is None

        # An x86-64-v2 CPU: the floor is opened (and refused by its ABI
        # version, which names that file), the runtime check given the
        # directory's own lib/.
        calls.clear()
        cpuinfo[0] = fixture("cpuinfo_x86_64_westmere.txt")
        got = refused(lambda: _native.load(native_dir), LibraryLoadError)
        floor_file = os.path.join(native_dir, "libkomira.so")
        assert got == "libkomira at {} has ABI version 2.0; this package needs major 1".format(floor_file), got
        assert calls == [("select", native_dir), ("runtime", os.path.join(native_dir, "lib")), ("open", floor_file)]
        assert _native._loaded is None

        # The x86-64-v3 CPU: the level two directories down is opened and
        # kept, and the runtime check is still given the directory's lib/, not
        # one beside the variant.
        calls.clear()
        cpuinfo[0] = fixture("cpuinfo_x86_64_v3.txt")
        native = _native.load(pathlib.Path(native_dir))
        assert calls == [("select", native_dir), ("runtime", os.path.join(native_dir, "lib")), ("open", native_v3)]
        assert native.path == native_v3 and native.abi_version == 1003, (native.path, native.abi_version)
        assert _native._loaded is native

        # The same directory again, or no directory, is the same library and
        # reads no CPU: the cpuinfo is gone now.
        calls.clear()
        cpuinfo[0] = gone
        assert _native.load(native_dir) is native
        assert _native.load() is native
        assert calls == [], calls
        # Another directory is refused, and the first library stays.
        got = refused(lambda: _native.load(shipped_dir), LibraryLoadError)
        want = "libkomira is already loaded from {}; it cannot also be loaded from {}".format(
            native_v3, os.path.join(shipped_dir, _native._LIB_NAME)
        )
        assert got == want, got
        assert calls == [] and _native._loaded is native, calls
    finally:
        ctypes.CDLL = cdll
        _runtime.check_loaded_runtime = check_runtime
        _native._check_cpu = check_cpu
        _native._select_variant = select


main(sys.argv[1:])
