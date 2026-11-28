# The dynamic symbol table defines exactly the exports `_exports` lists (BUCK's
# `exports`), and nothing else.
#
# A gate driver of //src/so:libkomira. It has no dependency. The
# exports check proves those names resolve; this proves no other name is
# defined. On Linux it reads ./libkomira.so as an ELF64 file, walks the
# SHT_DYNSYM section and lists every defined symbol: an `@export` the BUCK
# `exports` list omits, a symbol of a static C dependency, or a linker marker
# (`_init`, `_end`) shows up here unless the version script of `exports_exact`
# made it local. On macOS the dynamic table is not read (the exports list file
# of `exports_exact` is the guard there) and the driver only looks the linker
# markers up with dlsym.

from std.ffi import OwnedDLHandle
from std.pathlib import Path
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
comptime SHT_DYNSYM = 11


def _u(data: List[UInt8], at: Int, n: Int) raises -> Int:
    """The little-endian unsigned integer of `n` bytes at `at`."""
    if at < 0 or at + n > len(data):
        raise Error("ELF read past the end of the file")
    var v = 0
    for i in range(n):
        v |= Int(data[at + i]) << (8 * i)
    return v


def _cstr(data: List[UInt8], at: Int) raises -> String:
    var out = List[UInt8]()
    var i = at
    while _u(data, i, 1) != 0:
        out.append(data[i])
        i += 1
    return String(unsafe_from_utf8=out)


def _defined_dynsyms(data: List[UInt8]) raises -> List[String]:
    if len(data) < 64 or _u(data, 0, 4) != 0x464C457F or _u(data, 4, 1) != 2:
        raise Error("not an ELF64 file")
    var shoff = _u(data, 0x28, 8)
    var shentsize = _u(data, 0x3A, 2)
    var shnum = _u(data, 0x3C, 2)
    var names = List[String]()
    var found = False
    for s in range(shnum):
        var sh = shoff + s * shentsize
        if _u(data, sh + 4, 4) != SHT_DYNSYM:
            continue
        found = True
        var off = _u(data, sh + 0x18, 8)
        var size = _u(data, sh + 0x20, 8)
        var strsh = shoff + _u(data, sh + 0x28, 4) * shentsize
        var stroff = _u(data, strsh + 0x18, 8)
        var count = size // 24
        for i in range(count):
            var sym = off + i * 24
            var name_at = _u(data, sym, 4)
            # Index 0 is the null symbol; shndx 0 is an import, not a definition.
            if name_at == 0 or _u(data, sym + 6, 2) == 0:
                continue
            names.append(_cstr(data, stroff + name_at))
    if not found:
        raise Error("the library has no dynamic symbol table")
    return names^


def _exports() -> List[String]:
    """The names BUCK's `exports` lists, one per line: the count the symbol
    table is held to is the length of this list, so a new export adds a line
    and edits no number."""
    var names = List[String]()
    names.append("komira_abi_version")
    names.append("komira_ctx_new")
    names.append("komira_ctx_free")
    names.append("komira_last_error")
    names.append("komira_last_error_code")
    names.append("komira_last_error_step")
    names.append("komira_register_parquet")
    names.append("komira_parquet_schema")
    names.append("komira_csv_binding")
    names.append("komira_json_binding")
    names.append("komira_plan_render")
    names.append("komira_credential_add")
    names.append("komira_credential_set")
    names.append("komira_credential_seal")
    names.append("komira_sql_stream")
    names.append("komira_ctx_new_with_options")
    names.append("komira_register_csv")
    names.append("komira_register_json")
    names.append("komira_run_new")
    names.append("komira_run_free")
    names.append("komira_run_cancel")
    names.append("komira_run_progress")
    names.append("komira_sql_stream_run")
    names.append("komira_plan_stream")
    names.append("komira_register_arrow_stream")
    names.append("komira_add_sql_binding")
    return names^


def _is_export(name: String, exports: List[String]) -> Bool:
    for i in range(len(exports)):
        if exports[i] == name:
            return True
    return False


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var extra = 0

    comptime if CompilationTarget.is_macos():
        # The linker markers a link without an exports list would leave visible.
        for name in ["_init", "_fini", "_edata", "_end", "__bss_start"]:
            if lib.check_symbol(name):
                print("UNEXPECTED EXPORT: " + String(name))
                extra += 1
    else:
        var exports = _exports()
        var names = _defined_dynsyms(Path(LIB).read_bytes())
        var seen = 0
        for name in names:
            if _is_export(name, exports):
                seen += 1
            else:
                print("UNEXPECTED EXPORT: " + name)
                extra += 1
        if seen != len(exports):
            raise Error(
                "expected "
                + String(len(exports))
                + " defined exports, the symbol table has "
                + String(seen)
            )
    if extra != 0:
        raise Error(String(extra) + " symbol(s) outside the exports are defined")
    print("ok")
