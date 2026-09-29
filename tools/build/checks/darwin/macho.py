"""Static checks of the macOS arm64 toolchain closure, from Mach-O load commands.

usage: macho.py <compiler_dir> <runtime_dir> <deployment_target>

The darwin counterpart of the loader trace the linux checks read: no macOS host
runs here, so what a binary will load is read from its load commands instead.
Checks, printing one line per problem and exiting 1 if there is any:

  * bin/mojo and bin/lld are 64-bit arm64 Mach-O executables, and both are in
    CLOSURE_MANIFEST (the compiler links with bin/lld).
  * the runtime directory holds exactly the compiler's lib/*.dylib, byte for
    byte: a runnable directory carries every library the binary can load.
  * every closure binary loads only @rpath/<a runtime library>, or a system
    library (/usr/lib/, /System/Library/); nothing from a developer tool, a
    package manager or a build machine.
  * every run path is @loader_path-relative, and every library's install name
    is @rpath/<its file name>.
  * no binary requires a newer macOS than the deployment target.
"""

import os
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_WEAK_DYLIB = 0xC, 0xD, 0x80000018
LC_REEXPORT_DYLIB, LC_RPATH, LC_BUILD_VERSION = 0x8000001F, 0x8000001C, 0x32
DYLIB_CMDS = {LC_LOAD_DYLIB: "load", LC_LOAD_WEAK_DYLIB: "load", LC_REEXPORT_DYLIB: "load", LC_ID_DYLIB: "id"}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")


def version(v):
    return (v >> 16, (v >> 8) & 0xFF, v & 0xFF)


def load_commands(path):
    """(filetype, cputype, [(kind, value)]) of a thin 64-bit Mach-O file."""
    with open(path, "rb") as f:
        b = f.read()
    if len(b) < 32 or struct.unpack_from("<I", b, 0)[0] != MH_MAGIC_64:
        raise ValueError("not a 64-bit little-endian Mach-O file")
    cputype, _, filetype, ncmds = struct.unpack_from("<IIII", b, 4)
    off, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", b, off)
        if cmd in DYLIB_CMDS or cmd == LC_RPATH:
            name_off = struct.unpack_from("<I", b, off + 8)[0]
            name = b[off + name_off:off + size].split(b"\0")[0].decode()
            out.append(("rpath" if cmd == LC_RPATH else DYLIB_CMDS[cmd], name))
        elif cmd == LC_BUILD_VERSION:
            out.append(("minos", version(struct.unpack_from("<I", b, off + 12)[0])))
        off += size
    return filetype, cputype, out


def main(compiler, runtime, deployment_target):
    problems = []
    target = tuple(int(x) for x in (deployment_target.split(".") + ["0", "0"])[:3])
    manifest = open(os.path.join(compiler, "CLOSURE_MANIFEST")).read().split()
    libs = sorted(n for n in os.listdir(os.path.join(compiler, "lib")) if n.endswith(".dylib"))
    if not libs:
        problems.append("compiler lib/ holds no .dylib")
    carried = sorted(os.listdir(runtime))
    if carried != libs:
        problems.append("runtime directory holds %s, the compiler's lib/ %s" % (carried, libs))
    for name in set(carried) & set(libs):
        if open(os.path.join(runtime, name), "rb").read() != open(os.path.join(compiler, "lib", name), "rb").read():
            problems.append("runtime %s differs from the compiler's lib/%s" % (name, name))
    binaries = [("bin/mojo", 2), ("bin/lld", 2)] + [("lib/" + n, 6) for n in libs]
    for rel, want_type in binaries:
        if rel not in manifest:
            problems.append("%s is not in CLOSURE_MANIFEST" % rel)
        try:
            filetype, cputype, cmds = load_commands(os.path.join(compiler, rel))
        except (OSError, ValueError, struct.error) as e:
            problems.append("%s: %s" % (rel, e))
            continue
        if cputype != CPU_TYPE_ARM64 or filetype != want_type:
            problems.append("%s: cputype %#x filetype %d, want arm64 filetype %d" % (rel, cputype, filetype, want_type))
        for kind, value in cmds:
            if kind == "load":
                ok = value.startswith(SYSTEM_PREFIXES) or (value.startswith("@rpath/") and value[7:] in libs)
                if not ok:
                    problems.append("%s loads %s: neither a runtime library nor a system library" % (rel, value))
            elif kind == "id" and value != "@rpath/" + os.path.basename(rel):
                problems.append("%s: install name %s, want @rpath/%s" % (rel, value, os.path.basename(rel)))
            elif kind == "rpath" and not value.startswith("@loader_path"):
                problems.append("%s: run path %s is not @loader_path-relative" % (rel, value))
            elif kind == "minos" and value > target:
                problems.append("%s requires macOS %s, newer than the deployment target %s" % (rel, ".".join(map(str, value)), deployment_target))
    for p in problems:
        print(p)
    if problems:
        return 1
    print("%d Mach-O files: arm64, loading only @rpath runtime libraries and the system; %d runtime libraries carried" % (len(binaries), len(libs)))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
