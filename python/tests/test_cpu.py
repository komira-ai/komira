"""The CPU check that runs before libkomira is opened: on Linux x86_64 a CPU
without the flags of x86-64-v3 is refused with UnsupportedCpuError naming the
missing flags, before the library is mapped; a CPU with them passes; on
other platforms nothing is read.

    test_cpu.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/cpuinfo_x86_64_v3.txt` is /proc/cpuinfo of an x86-64-v3 CPU (two
processors) and `<dir>/fake_v1_3/libkomira.so` a stand-in library of
fake_libkomira.c that loads (`--runtime-dir`, which the rule passes, is not
read). The cpuinfo files the cases need beyond the fixture are written from it
into the test's temporary directory.
"""

import ctypes
import os
import pathlib
import platform
import sys
import tempfile

import komira
from komira import KomiraError, LibraryLoadError, UnsupportedCpuError
from komira import _native, _runtime

V3 = ("pni", "ssse3", "cx16", "sse4_1", "sse4_2", "popcnt", "lahf_lm")
V3 += ("avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "abm", "movbe")


def refusal(path, missing):
    return (
        "libkomira for Linux x86_64 needs an x86-64-v3 CPU (Haswell or newer); "
        "this CPU lacks {} (the flags {} lists)".format(", ".join(missing), path)
    )


def cpu_error(call):
    try:
        call()
    except UnsupportedCpuError as e:
        assert type(e) is UnsupportedCpuError, repr(e)
        assert e.status is None, e.status
        return str(e)
    raise AssertionError("the CPU was not refused")


def x86(path):
    return _native._check_cpu(path, system="linux", machine="x86_64")


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    real = os.path.join(lib_dir, "cpuinfo_x86_64_v3.txt")
    with open(real, encoding="utf-8") as f:
        text = f.read()
    scratch = tempfile.mkdtemp()

    def planted(name, content):
        path = os.path.join(scratch, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return path

    def without(content, drop, processor=None):
        """`content` with the flags `drop` taken off the `flags` line of every
        processor, or only of the `processor`-th one (from 0)."""
        out, seen = [], -1
        for line in content.split("\n"):
            key, _, value = line.partition(":")
            if key.strip() == "flags":
                seen += 1
                if processor is None or processor == seen:
                    line = key + ": " + " ".join(f for f in value.split() if f not in drop)
            out.append(line)
        return "\n".join(out)

    # The error is public and a LibraryLoadError, so `except
    # komira.LibraryLoadError` still catches every refused load.
    assert "UnsupportedCpuError" in komira.__all__, komira.__all__
    assert komira.UnsupportedCpuError is UnsupportedCpuError
    assert issubclass(UnsupportedCpuError, LibraryLoadError) and issubclass(UnsupportedCpuError, KomiraError)

    # The flag list is x86-64-v3's, in its cpuinfo spelling (LZCNT is `abm`),
    # and the fixture of a real x86-64-v3 CPU lists every one and passes.
    assert _native._X86_64_V3_FLAGS == V3, _native._X86_64_V3_FLAGS
    assert x86(real) is None
    assert set(V3) <= _native._cpu_flags(text)
    # The words of the vmx flags and bugs lines are not flags.
    assert "preemption_timer" not in _native._cpu_flags(text) and "spectre_v1" not in _native._cpu_flags(text)

    # Without avx2, the refusal names avx2 alone, and the file it read.
    no_avx2 = planted("no_avx2", without(text, {"avx2"}))
    assert cpu_error(lambda: x86(no_avx2)) == refusal(no_avx2, ["avx2"])

    # Several missing are named in the list's order, whatever order the line
    # had; an x86-64-v2 CPU lacks exactly x86-64-v3's own eight.
    some = planted("some", without(text, {"movbe", "bmi2", "fma"}))
    assert cpu_error(lambda: x86(some)) == refusal(some, ["bmi2", "fma", "movbe"])
    v2 = planted("v2", without(text, set(V3[7:])))
    assert cpu_error(lambda: x86(v2)) == refusal(v2, list(V3[7:]))
    # Each flag on its own is required.
    for flag in V3:
        one = planted("one_" + flag, without(text, {flag}))
        assert cpu_error(lambda: x86(one)) == refusal(one, [flag]), flag

    # A flag counts only when every processor lists it.
    second = planted("second", without(text, {"avx2"}, processor=1))
    assert cpu_error(lambda: x86(second)) == refusal(second, ["avx2"])
    first = planted("first", without(text, {"bmi1"}, processor=0))
    assert cpu_error(lambda: x86(first)) == refusal(first, ["bmi1"])

    # A flag is a whole word: avx2 and avx512f do not give avx.
    no_avx = planted("no_avx", without(text, {"avx"}).replace(" avx2 ", " avx2 avx512f "))
    assert cpu_error(lambda: x86(no_avx)) == refusal(no_avx, ["avx"])

    # Only the `flags` key counts: a vmx flags line listing avx2 does not
    # stand in for it, and the key may be padded with tabs or spaces.
    vmx = planted("vmx", without(text, {"avx2"}).replace("vmx flags\t: ", "vmx flags\t: avx2 "))
    assert cpu_error(lambda: x86(vmx)) == refusal(vmx, ["avx2"])
    spaced = planted("spaced", "processor : 0\nflags   :   " + "   ".join(V3) + "  \n")
    assert x86(spaced) is None
    bare = planted("bare", "flags:" + " ".join(V3))
    assert x86(bare) is None

    # No flags line, an empty flags line and an empty file are no flags.
    no_line = planted("no_line", without(text, set()).replace("flags\t\t", "flagz\t\t"))
    assert cpu_error(lambda: x86(no_line)) == refusal(no_line, list(V3))
    empty_line = planted("empty_line", "processor\t: 0\nflags\t\t:\n")
    assert cpu_error(lambda: x86(empty_line)) == refusal(empty_line, list(V3))
    empty = planted("empty", "")
    assert cpu_error(lambda: x86(empty)) == refusal(empty, list(V3))

    # A cpuinfo that cannot be read is a LibraryLoadError, not a pass and not
    # a claim about the CPU; the message names the file.
    missing = os.path.join(scratch, "no_such_cpuinfo")
    try:
        x86(missing)
    except UnsupportedCpuError as e:
        raise AssertionError("an unreadable cpuinfo is not an unsupported CPU: {!r}".format(e))
    except LibraryLoadError as e:
        want = (
            "cannot read the CPU flags from {0}, so it is not known whether this CPU implements x86-64-v3, "
            "which libkomira for Linux x86_64 needs: [Errno 2] No such file or directory: '{0}'".format(missing)
        )
        assert str(e) == want and e.status is None, str(e)
    else:
        raise AssertionError("an unreadable cpuinfo passed")
    # A path may be an os.PathLike.
    assert x86(pathlib.Path(real)) is None
    assert cpu_error(lambda: x86(pathlib.Path(no_avx2))) == refusal(no_avx2, ["avx2"])

    # On aarch64 Linux and on macOS nothing is read: an unreadable or
    # flagless cpuinfo is not refused.
    for system, machine in [("linux", "aarch64"), ("darwin", "arm64"), ("darwin", "x86_64"), ("linux", "i686")]:
        assert _native._check_cpu(missing, system=system, machine=machine) is None, (system, machine)
        assert _native._check_cpu(no_avx2, system=system, machine=machine) is None, (system, machine)

    # With no file, the check reads _native._CPUINFO; with no system or
    # machine, it takes this interpreter's. The default path is pointed at
    # the cpuinfo without avx2, so the real /proc/cpuinfo is never read.
    default_cpuinfo = _native._CPUINFO
    assert default_cpuinfo == "/proc/cpuinfo"
    _native._CPUINFO = no_avx2
    assert cpu_error(lambda: _native._check_cpu(system="linux", machine="x86_64")) == refusal(no_avx2, ["avx2"])
    here = sys.platform == "linux" and platform.machine() == "x86_64"
    if here:
        assert cpu_error(_native._check_cpu) == refusal(no_avx2, ["avx2"])
    else:
        assert _native._check_cpu() is None
    _native._CPUINFO = real
    assert _native._check_cpu() is None

    # load runs the check before it opens the library: with the cpuinfo
    # without avx2, the stand-in (which loads) is never handed to the dynamic
    # loader, and nothing is loaded.
    fake = os.path.join(lib_dir, "fake_v1_3")
    check = _native._check_cpu
    _native._check_cpu = lambda: check(no_avx2, system="linux", machine="x86_64")
    opened = []
    cdll = ctypes.CDLL

    def recording_cdll(path, *a, **k):
        opened.append(path)
        return cdll(path, *a, **k)

    ctypes.CDLL = recording_cdll
    try:
        got = cpu_error(lambda: _native.load(fake))
        assert got == refusal(no_avx2, ["avx2"]), got
        assert opened == [] and _native._loaded is None, opened
        # Session() and abi_version() load the same way and are refused the same.
        assert cpu_error(komira.abi_version) == refusal(no_avx2, ["avx2"])

        # With the cpuinfo of the x86-64-v3 CPU the same load goes on: on Linux
        # the runtime check asks for each Mojo runtime library by name with
        # RTLD_NOLOAD (none is loaded, and that opens nothing; it does nothing
        # on another system), then the library is opened by its path.
        _native._check_cpu = lambda: check(real, system="linux", machine="x86_64")
        native = _native.load(fake)
        asked = list(_runtime.RUNTIME_LIBRARIES) if sys.platform == "linux" else []
        assert opened == asked + [os.path.join(fake, _native._LIB_NAME)], opened
        assert native.abi_version == 1003 and _native._loaded is native
    finally:
        ctypes.CDLL = cdll
        _native._check_cpu = check
        _native._CPUINFO = default_cpuinfo


main(sys.argv[1:])
