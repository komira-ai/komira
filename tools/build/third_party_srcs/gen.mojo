"""gen: the source lists of a vendored C library, read out of its pinned
release archive.

    gen <library> <archive.tar> <out> <gen-label> <drift-label> <committed-path>

<library> is aws-lc or s2n-tls; <archive.tar> is the release archive,
uncompressed (the rule in defs.bzl decompresses it). Writes the library's
srcs.bzl to <out>: the lists the library's own CMake build compiles for the
configuration third_party/<library>/BUCK builds (see the comments in each
section below). Every list is read from the archive's CMakeLists.txt, and
every file it names must exist in the archive. The header lists are the
closure of the `#include`s of the listed sources, so a compile action gets
exactly the headers its sources can reach. The three labels and the path
only fill in the file's header: how to regenerate it, and which test holds
it to the archive.

Exits 1 naming what changed in the archive when the CMake lists no longer
read the way this program expects.
"""

from std.collections import Dict
from std.sys import argv, exit
from buildtools.bytes import (
    byte_at,
    dirname,
    is_space,
    is_word,
    join,
    normpath,
    path_join,
    read_file,
    slice_string,
    sort_strings,
    split_words,
    substr,
    suffix,
)
from buildtools.tar import read_tar


def die(msg: String):
    print("gen: " + msg)
    exit(1)


# ---- the archive -------------------------------------------------------------


struct Archive(Movable):
    var data: List[UInt8]
    var prefix: String
    # Every regular file, relative to the top directory.
    var all: Dict[String, Int]
    var all_sorted: List[String]
    # The .c .cc .h .S .txt .flags .inc files: relative path -> member index.
    var offsets: Dict[String, Int]
    var sizes: Dict[String, Int]

    def __init__(out self, path: String) raises:
        self.data = read_file(path)
        var members = read_tar(self.data)
        self.all = Dict[String, Int]()
        self.all_sorted = List[String]()
        self.offsets = Dict[String, Int]()
        self.sizes = Dict[String, Int]()
        var roots = List[String]()
        for i in range(len(members)):
            if not members[i].is_file():
                continue
            var name = members[i].name
            var slash = name.find("/")
            var root = name if slash < 0 else substr(name, 0, slash)
            var known = False
            for r in range(len(roots)):
                if roots[r] == root:
                    known = True
            if not known:
                roots.append(root)
        if len(roots) != 1:
            die(path + " has " + String(len(roots)) + " top-level directories, expected one")
        self.prefix = roots[0]
        var cut = self.prefix.byte_length() + 1
        for i in range(len(members)):
            if not members[i].is_file():
                continue
            var rel = suffix(members[i].name, cut)
            self.all[rel] = 1
            self.all_sorted.append(rel)
            if (
                rel.endswith(".c")
                or rel.endswith(".cc")
                or rel.endswith(".h")
                or rel.endswith(".S")
                or rel.endswith(".txt")
                or rel.endswith(".flags")
                or rel.endswith(".inc")
            ):
                self.offsets[rel] = members[i].offset
                self.sizes[rel] = members[i].size
        sort_strings(self.all_sorted)

    def has_file(self, rel: String) -> Bool:
        return rel in self.offsets

    def has(self, rel: String) -> Bool:
        return rel in self.all

    def text(self, rel: String) raises -> String:
        if rel not in self.offsets:
            die(rel + " is not in the archive")
        var off = self.offsets[rel]
        return slice_string(self.data, off, off + self.sizes[rel])

    def need(self, rel: String) -> String:
        if rel not in self.all:
            die("the CMake lists name " + rel + ", which is not in the archive")
        return rel


# ---- a small regular-expression search ----------------------------------------
#
# Enough of Python's `re` for the anchors below: literal characters (`\(`,
# `\)`, `\"` and other escaped punctuation), `\s`, `\b`, `[\s\S]`, `[^\n]`,
# and the quantifiers `*`, `+` and lazy `*?`. search() returns the end of the
# leftmost match, as re.search(...).end() does, or -1.

comptime _LIT = 0
comptime _WS = 1
comptime _ANY = 2
comptime _NOTNL = 3
comptime _WORDB = 4

comptime _ONE = 0
comptime _STAR = 1
comptime _PLUS = 2
comptime _LAZY = 3


struct Pattern(Movable):
    var kinds: List[Int]
    var chars: List[Int]
    var quants: List[Int]

    def __init__(out self, src: String) raises:
        self.kinds = List[Int]()
        self.chars = List[Int]()
        self.quants = List[Int]()
        var n = src.byte_length()
        var i = 0
        while i < n:
            var c = byte_at(src, i)
            var kind = _LIT
            var ch = c
            if c == 92:
                if i + 1 >= n:
                    raise Error("pattern ends in a backslash")
                var e = byte_at(src, i + 1)
                i += 2
                if e == 115:
                    kind = _WS
                elif e == 98:
                    kind = _WORDB
                elif e == 110:
                    ch = 10
                elif is_word(e):
                    raise Error("unsupported escape \\" + chr(e))
                else:
                    ch = e
            elif c == 91:
                var rest = suffix(src, i)
                if rest.startswith("[\\s\\S]"):
                    kind = _ANY
                    i += 6
                elif rest.startswith("[^\\n]"):
                    kind = _NOTNL
                    i += 5
                else:
                    raise Error("unsupported class in " + src)
            elif c == 40 or c == 41 or c == 124 or c == 63 or c == 42 or c == 43 or c == 94 or c == 36 or c == 46:
                raise Error("unsupported operator '" + chr(c) + "' in " + src)
            else:
                i += 1
            var q = _ONE
            if i < n and byte_at(src, i) == 42:
                q = _STAR
                i += 1
                if i < n and byte_at(src, i) == 63:
                    q = _LAZY
                    i += 1
            elif i < n and byte_at(src, i) == 43:
                q = _PLUS
                i += 1
            self.kinds.append(kind)
            self.chars.append(ch)
            self.quants.append(q)

    def _one(self, k: Int, text: String, pos: Int) -> Bool:
        """Whether token k's atom matches the byte at pos."""
        if pos >= text.byte_length():
            return False
        var c = byte_at(text, pos)
        var kind = self.kinds[k]
        if kind == _LIT:
            return c == self.chars[k]
        if kind == _WS:
            return is_space(c)
        if kind == _ANY:
            return True
        return c != 10

    def _match(self, k: Int, text: String, pos: Int) -> Int:
        if k == len(self.kinds):
            return pos
        var n = text.byte_length()
        if self.kinds[k] == _WORDB:
            var before = pos > 0 and is_word(byte_at(text, pos - 1))
            var after = pos < n and is_word(byte_at(text, pos))
            if before == after:
                return -1
            return self._match(k + 1, text, pos)
        var q = self.quants[k]
        if q == _ONE:
            if self._one(k, text, pos):
                return self._match(k + 1, text, pos + 1)
            return -1
        if q == _LAZY:
            var j = pos
            while True:
                var r = self._match(k + 1, text, j)
                if r >= 0:
                    return r
                if not self._one(k, text, j):
                    return -1
                j += 1
        var run = 0
        while self._one(k, text, pos + run):
            run += 1
        var least = 1 if q == _PLUS else 0
        var j = run
        while j >= least:
            var r = self._match(k + 1, text, pos + j)
            if r >= 0:
                return r
            j -= 1
        return -1

    def search(self, text: String) -> Int:
        for start in range(text.byte_length() + 1):
            var r = self._match(0, text, start)
            if r >= 0:
                return r
        return -1


def cmake_block(text: String, anchor: String, what: String) raises -> List[String]:
    """The whitespace-separated words after `anchor`, up to the next `)`."""
    var end = Pattern(anchor).search(text)
    if end < 0:
        die("no " + what + " in the CMake lists (pattern '" + anchor + "'); update gen.mojo")
    var words = List[String]()
    var n = text.byte_length()
    var i = end
    while i < n:
        # One line, as str.splitlines() cuts them.
        var j = i
        while j < n:
            var c = byte_at(text, j)
            if c == 10 or c == 13 or c == 11 or c == 12 or c == 28 or c == 29 or c == 30:
                break
            j += 1
        var line = substr(text, i, j)
        var hash = line.find("#")
        if hash >= 0:
            line = substr(line, 0, hash)
        var close = line.find(")")
        var ws = split_words(line if close < 0 else substr(line, 0, close))
        for w in range(len(ws)):
            words.append(ws[w])
        if close >= 0:
            return words^
        if j < n and byte_at(text, j) == 13 and j + 1 < n and byte_at(text, j + 1) == 10:
            j += 1
        i = j + 1
    die("the " + what + " list is not closed")
    return words^


def only_files(words: List[String], allowed: List[String], what: String) -> List[String]:
    var out = List[String]()
    for i in range(len(words)):
        var w = words[i]
        if w.startswith("${"):
            var ok = False
            for a in range(len(allowed)):
                if allowed[a] == w:
                    ok = True
            if not ok:
                die(what + " names " + w + ", which gen.mojo does not handle")
            continue
        out.append(w)
    return out^


def _includes(text: String) -> List[String]:
    """The quoted and angle #include names, each prefixed by its kind
    (`"` or `<`), in order: Python's
    re.findall(r'^\\s*#\\s*include\\s*([<"])([^>"]+)[>"]', text, re.M)."""
    var out = List[String]()
    var n = text.byte_length()
    var pos = 0
    var ls = 0
    while ls <= n:
        if ls >= pos:
            var i = ls
            while i < n and is_space(byte_at(text, i)):
                i += 1
            var ok = i < n and byte_at(text, i) == 35
            if ok:
                i += 1
                while i < n and is_space(byte_at(text, i)):
                    i += 1
                ok = substr(text, i, i + 7) == "include"
            if ok:
                i += 7
                while i < n and is_space(byte_at(text, i)):
                    i += 1
                ok = i < n and (byte_at(text, i) == 60 or byte_at(text, i) == 34)
            if ok:
                var kind = substr(text, i, i + 1)
                i += 1
                var start = i
                while i < n and byte_at(text, i) != 62 and byte_at(text, i) != 34:
                    i += 1
                if i > start and i < n:
                    out.append(kind + substr(text, start, i))
                    pos = i + 1
        # The next line start.
        var nl = text.find("\n", ls)
        if nl < 0:
            break
        ls = nl + 1
    return out^


def include_closure(arc: Archive, sources: List[String], roots: List[String]) raises -> List[String]:
    """Every archive file reachable from `sources` through #include.

    A quoted include resolves against the including file's directory first,
    then against `roots` (the -I directories); an angle include against
    `roots` only. An include that resolves nowhere is a system header (or
    sits behind an #if this configuration does not take) and is skipped.
    """
    var seen = Dict[String, Int]()
    var todo = sources.copy()
    while len(todo) > 0:
        var f = todo.pop()
        var text = arc.text(f) if arc.has_file(f) else String("")
        var incs = _includes(text)
        for k in range(len(incs)):
            var kind = substr(incs[k], 0, 1)
            var name = suffix(incs[k], 1)
            var cands = List[String]()
            if kind == '"':
                cands.append(normpath(path_join(dirname(f), name)))
            for r in range(len(roots)):
                cands.append(normpath(path_join(roots[r], name)))
            for c in range(len(cands)):
                if arc.has_file(cands[c]):
                    if cands[c] not in seen:
                        seen[cands[c]] = 1
                        todo.append(cands[c])
                    break
    var out = List[String]()
    for e in seen.items():
        out.append(e.key)
    sort_strings(out)
    return out^


# ---- output ------------------------------------------------------------------


def _comment(mut lines: List[String], comment: String):
    lines.append(String(""))
    var parts = comment.split("\n")
    for i in range(len(parts)):
        var l = String(parts[i])
        lines.append(("# " + l) if l.byte_length() > 0 else String("#"))


def bzl_list(mut lines: List[String], name: String, items: List[String], comment: String):
    _comment(lines, comment)
    lines.append(name + " = [")
    for i in range(len(items)):
        lines.append('    "' + items[i] + '",')
    lines.append("]")


def bzl_dict(mut lines: List[String], name: String, keys: List[String], values: List[String], comment: String):
    """`keys` must be sorted and unique; values[i] belongs to keys[i]."""
    _comment(lines, comment)
    lines.append(name + " = {")
    for i in range(len(keys)):
        lines.append('    "' + keys[i] + '": "' + values[i] + '",')
    lines.append("}")


struct Labels(Copyable, Movable):
    var gen: String
    var drift: String
    var committed: String

    def __init__(out self, gen: String, drift: String, committed: String):
        self.gen = gen
        self.drift = drift
        self.committed = committed


def header(library: String, arc: Archive, labels: Labels) -> List[String]:
    var out = List[String]()
    out.append("# Generated by " + labels.gen + " from the " + library + " archive (" + arc.prefix + "); do not edit.")
    out.append("# Regenerate: ./buck2 build " + labels.gen + " --out " + labels.committed + ". The drift test")
    out.append("# " + labels.drift + " fails when this file and the archive disagree.")
    return out^


def _prefixed(prefix: String, xs: List[String]) -> List[String]:
    var out = List[String]()
    for i in range(len(xs)):
        out.append(prefix + xs[i])
    return out^


def _asm_ext(xs: List[String]) -> List[String]:
    var out = List[String]()
    for i in range(len(xs)):
        out.append(xs[i].replace("${ASM_EXT}", "S"))
    return out^


# ---- aws-lc -------------------------------------------------------------------
#
# The configuration: libcrypto, not FIPS, a Release build without Perl or Go
# -- the pre-generated assembly and err_data.c that the archive ships under
# generated-src/ -- and Dilithium off (the CMake defaults for everything
# else); and libssl with the bssl tool, which BUILD_LIBSSL and BUILD_TOOL (on
# by default) add, as their own lists (see ssl_and_tool).


def ssl_and_tool(arc: Archive) raises -> Tuple[List[String], List[String], List[String]]:
    """libssl's sources (ssl/CMakeLists.txt: add_library(ssl)), the bssl
    tool's (tool/CMakeLists.txt: add_executable(bssl)), and every other file
    they #include outside the public headers, by archive path (they include
    them relatively, or as <openssl/...> from include/)."""
    var none = List[String]()
    var ssl_words = only_files(
        cmake_block(arc.text("ssl/CMakeLists.txt"), "add_library\\(\\s*ssl\\b", "ssl library"), none, "ssl"
    )
    var ssl = List[String]()
    for i in range(len(ssl_words)):
        ssl.append(arc.need("ssl/" + ssl_words[i]))
    var tool_words = only_files(
        cmake_block(arc.text("tool/CMakeLists.txt"), "add_executable\\(\\s*bssl\\b", "bssl executable"), none, "bssl"
    )
    var tool = List[String]()
    for i in range(len(tool_words)):
        tool.append(arc.need("tool/" + tool_words[i]))
    var sources = ssl.copy()
    for i in range(len(tool)):
        sources.append(tool[i])
    var roots: List[String] = ["include"]
    var closure = include_closure(arc, sources, roots)
    var headers = List[String]()
    for i in range(len(closure)):
        var f = closure[i]
        if f.startswith("include/"):
            if not (f.startswith("include/openssl/") and f.endswith(".h")):
                die(f + " is reached through #include but is not a public header")
            continue
        headers.append(f)
    return (ssl^, tool^, headers^)


def aws_lc(arc: Archive, labels: Labels) raises -> List[String]:
    var crypto_cmake = arc.text("crypto/CMakeLists.txt")
    var fips_cmake = arc.text("crypto/fipsmodule/CMakeLists.txt")

    var allowed: List[String] = ["${DILITHIUM_SOURCES}", "${CRYPTO_ARCH_SOURCES}", "${CRYPTO_ARCH_OBJECTS}"]
    var words = only_files(
        cmake_block(crypto_cmake, "add_library\\(\\s*crypto_objects\\s+OBJECT\\b", "crypto_objects library"),
        allowed,
        "crypto_objects",
    )
    # err_data.c is written into the build directory: by Go, or (without
    # Go) copied from the shipped generated-src/err_data.c.
    var crypto_c = List[String]()
    for i in range(len(words)):
        crypto_c.append(arc.need("generated-src/err_data.c" if words[i] == "err_data.c" else "crypto/" + words[i]))

    # x86_64: the branch taken when the assembler handles AVX (it does).
    var x86_words = cmake_block(
        crypto_cmake,
        'if\\(ARCH STREQUAL "x86_64"\\)\\s*if\\(MY_ASSEMBLER_IS_TOO_OLD_FOR_AVX\\)[\\s\\S]*?else\\(\\)\\s*set\\(\\s*CRYPTO_ARCH_SOURCES\\b',
        "x86_64 CRYPTO_ARCH_SOURCES",
    )
    var crypto_asm_x86_64 = List[String]()
    for i in range(len(x86_words)):
        var f = x86_words[i].replace("${ASM_EXT}", "S")
        var gen = "generated-src/linux-x86_64/crypto/" + f
        crypto_asm_x86_64.append(gen if arc.has(gen) else arc.need("crypto/" + f))
    var crypto_asm_aarch64 = _asm_ext(
        cmake_block(
            crypto_cmake,
            'if\\(ARCH STREQUAL "aarch64"\\)\\s*set\\(\\s*CRYPTO_ARCH_SOURCES\\b',
            "aarch64 CRYPTO_ARCH_SOURCES",
        )
    )

    var bcm_allowed: List[String] = ["${BCM_ASM_SOURCES}", "${BCM_ASM_OBJECTS}"]
    var bcm_words = only_files(
        cmake_block(
            fips_cmake,
            'else\\(\\)\\s*set\\(BCM_ASM_OBJECTS \\"\\"\\)[\\s\\S]*?add_library\\(\\s*fipsmodule\\s+OBJECT\\b',
            "non-FIPS fipsmodule library",
        ),
        bcm_allowed,
        "fipsmodule",
    )
    var bcm_c = List[String]()
    for i in range(len(bcm_words)):
        bcm_c.append(arc.need("crypto/fipsmodule/" + bcm_words[i]))

    var bcm_x86 = _asm_ext(
        cmake_block(fips_cmake, 'if\\(ARCH STREQUAL "x86_64"\\)\\s*set\\(\\s*BCM_ASM_SOURCES\\b', "x86_64 BCM_ASM_SOURCES")
    )
    var bcm_asm_x86_64 = List[String]()
    for i in range(len(bcm_x86)):
        bcm_asm_x86_64.append(arc.need("generated-src/linux-x86_64/crypto/fipsmodule/" + bcm_x86[i]))
    var bcm_asm_aarch64 = _asm_ext(
        cmake_block(fips_cmake, 'if\\(ARCH STREQUAL "aarch64"\\)\\s*set\\(\\s*BCM_ASM_SOURCES\\b', "aarch64 BCM_ASM_SOURCES")
    )

    var s2n_words = cmake_block(fips_cmake, "set\\(\\s*S2N_BIGNUM_ASM_SOURCES\\b", "S2N_BIGNUM_ASM_SOURCES")
    var s2n_x86 = cmake_block(
        fips_cmake,
        'if\\(ARCH STREQUAL "x86_64"\\)\\s*#[^\\n]*[\\s\\S]*?list\\(APPEND S2N_BIGNUM_ASM_SOURCES\\b',
        "x86_64 S2N_BIGNUM_ASM_SOURCES",
    )
    var s2n_asm_x86_64 = List[String]()
    for i in range(len(s2n_x86)):
        s2n_words.append(s2n_x86[i])
    for i in range(len(s2n_words)):
        s2n_asm_x86_64.append(arc.need("third_party/s2n-bignum/x86_att/" + s2n_words[i]))

    var public = List[String]()
    for i in range(len(arc.all_sorted)):
        var f = arc.all_sorted[i]
        if f.startswith("include/openssl/") and f.endswith(".h"):
            public.append(f)
    var public_set = Dict[String, Int]()
    for i in range(len(public)):
        public_set[public[i]] = 1
    var roots: List[String] = ["include", "third_party/s2n-bignum/include"]
    var sources = crypto_c.copy()
    for i in range(len(crypto_asm_x86_64)):
        sources.append(crypto_asm_x86_64[i])
    for i in range(len(bcm_c)):
        sources.append(bcm_c[i])
    for i in range(len(bcm_asm_x86_64)):
        sources.append(bcm_asm_x86_64[i])
    for i in range(len(s2n_asm_x86_64)):
        sources.append(s2n_asm_x86_64[i])
    # A later file with the same key replaces an earlier one, in sorted order.
    var keys = List[String]()
    var values = List[String]()
    var index = Dict[String, Int]()
    var closure = include_closure(arc, sources, roots)
    var s2n_root = roots[1] + "/"
    for i in range(len(closure)):
        var f = closure[i]
        if f.startswith("include/"):
            if f not in public_set:
                die(f + " is reached through #include but is not a public header")
            continue
        var key = suffix(f, s2n_root.byte_length()) if f.startswith(s2n_root) else f
        if key in index:
            values[index[key]] = f
        else:
            index[key] = len(keys)
            keys.append(key)
            values.append(f)
    var sk = keys.copy()
    sort_strings(sk)
    var sv = List[String]()
    for i in range(len(sk)):
        sv.append(values[index[sk[i]]])

    var out = header("aws-lc", arc, labels)
    bzl_list(out, "CRYPTO_SRCS", crypto_c,
        "crypto/CMakeLists.txt: add_library(crypto_objects); err_data.c is the shipped\ngenerated-src/err_data.c.")
    bzl_list(out, "CRYPTO_ASM_X86_64", crypto_asm_x86_64,
        "crypto/CMakeLists.txt: CRYPTO_ARCH_SOURCES for x86_64 (an assembler with AVX),\n"
        + "from generated-src/linux-x86_64 when shipped there.")
    bzl_list(out, "BCM_SRCS", bcm_c, "crypto/fipsmodule/CMakeLists.txt: the non-FIPS add_library(fipsmodule).")
    bzl_list(out, "BCM_ASM_X86_64", bcm_asm_x86_64, "crypto/fipsmodule/CMakeLists.txt: BCM_ASM_SOURCES for x86_64.")
    bzl_list(out, "S2N_BIGNUM_ASM_X86_64", s2n_asm_x86_64,
        "crypto/fipsmodule/CMakeLists.txt: S2N_BIGNUM_ASM_SOURCES for x86_64 (compiled\n"
        + "with S2N_BN_HIDE_SYMBOLS and third_party/s2n-bignum/include on the path).")
    bzl_list(out, "CRYPTO_ASM_AARCH64", crypto_asm_aarch64,
        "Not built yet: CRYPTO_ARCH_SOURCES for aarch64, relative to\n"
        + "generated-src/<linux-aarch64 | ios-aarch64>/crypto/ (or crypto/).")
    bzl_list(out, "BCM_ASM_AARCH64", bcm_asm_aarch64,
        "Not built yet: BCM_ASM_SOURCES for aarch64, relative to\n"
        + "generated-src/<linux-aarch64 | ios-aarch64>/crypto/fipsmodule/.")
    bzl_list(out, "PUBLIC_HEADERS", public, "Every public header, include/openssl/**.h.")
    bzl_dict(out, "PRIVATE_HEADERS", sk, sv,
        "The other files the sources above #include, keyed by the name they are\n"
        + "included by from an -I directory (the archive path when included relatively).")
    var st = ssl_and_tool(arc)
    bzl_list(out, "SSL_SRCS", st[0], "ssl/CMakeLists.txt: add_library(ssl), libssl (C++ but for one C file).")
    bzl_list(out, "TOOL_SRCS", st[1], "tool/CMakeLists.txt: add_executable(bssl), the bssl tool (C++).")
    bzl_list(out, "SSL_TOOL_HEADERS", st[2],
        "The other files SSL_SRCS and TOOL_SRCS #include (the public headers aside),\n"
        + "by archive path: they include them relatively.")
    return out^


# ---- s2n-tls ------------------------------------------------------------------
#
# The library's sources are CMake GLOBs: crypto/*.c, error/*.c, stuffer/*.c,
# tls/**/*.c and utils/*.c. The feature probes are tests/features/*.c, each
# compiled with GLOBAL.flags and its own <probe>.flags.


def _flags(arc: Archive, name: String) raises -> String:
    return join(split_words(arc.text("tests/features/" + name + ".flags")), " ")


def _probe_name(f: String) -> String:
    """<NAME> for tests/features/<NAME>.c with NAME in [A-Z0-9_]+, else ""."""
    if not f.startswith("tests/features/") or not f.endswith(".c"):
        return String("")
    var name = substr(f, 15, f.byte_length() - 2)
    if name.byte_length() == 0:
        return String("")
    for i in range(name.byte_length()):
        var c = byte_at(name, i)
        if not ((c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 95):
            return String("")
    return name^


def s2n_tls(arc: Archive, labels: Labels) raises -> List[String]:
    var cmake = arc.text("CMakeLists.txt")
    var dirs: List[String] = ["crypto/", "error/", "stuffer/", "tls/", "utils/"]
    for d in range(len(dirs)):
        var recursive = dirs[d] == "tls/"
        var var_name = substr(dirs[d], 0, dirs[d].byte_length() - 1).upper()
        var glob = "file(GLOB" + ("_RECURSE" if recursive else "") + " " + var_name + '_SRC "' + dirs[d] + '*.c")'
        if cmake.find(glob) < 0:
            die("s2n-tls CMakeLists.txt no longer globs " + dirs[d] + "*.c the way gen.mojo expects")
    if cmake.lower().find('file(glob feature_srcs "${cmake_current_list_dir}/tests/features/*.c")') < 0:
        die("s2n-tls feature probes are no longer tests/features/*.c")

    var srcs = List[String]()
    for i in range(len(arc.all_sorted)):
        var f = arc.all_sorted[i]
        if not f.endswith(".c"):
            continue
        for d in range(len(dirs)):
            if f.startswith(dirs[d]) and (dirs[d] == "tls/" or suffix(f, dirs[d].byte_length()).find("/") < 0):
                srcs.append(f)
    sort_strings(srcs)
    var roots: List[String] = [".", "api"]
    var closure = include_closure(arc, srcs, roots)
    var private = List[String]()
    for i in range(len(closure)):
        if not closure[i].startswith("api/"):
            private.append(closure[i])
    var public = List[String]()
    for i in range(len(arc.all_sorted)):
        var f = arc.all_sorted[i]
        if f.startswith("api/") and f.endswith(".h"):
            public.append(f)

    var probe_names = List[String]()
    var probe_flags = List[String]()
    for i in range(len(arc.all_sorted)):
        var name = _probe_name(arc.all_sorted[i])
        if name.byte_length() > 0:
            probe_names.append(name)
            probe_flags.append(_flags(arc, name))

    var out = header("s2n-tls", arc, labels)
    bzl_list(out, "SRCS", srcs, "The library's sources (the CMake GLOBs).")
    bzl_list(out, "PUBLIC_HEADERS", public, "The public API, api/**.h (included as <s2n.h>, <s2n/unstable/...>).")
    bzl_dict(out, "PRIVATE_HEADERS", private, private,
        "The other headers the sources #include, by their path from the repository\n"
        + "root (the root is on the include path).")
    out.append(String(""))
    out.append("# tests/features/GLOBAL.flags, passed to every probe.")
    out.append('PROBE_GLOBAL_FLAGS = "' + _flags(arc, "GLOBAL") + '"')
    bzl_dict(out, "PROBES", probe_names, probe_flags,
        "Each feature probe, tests/features/<name>.c, and its <name>.flags.")
    return out^


def main() raises:
    var args = argv()
    if len(args) != 7:
        print("usage: gen aws-lc|s2n-tls <archive.tar> <out> <gen-label> <drift-label> <committed-path>")
        exit(2)
    var library = String(args[1])
    var arc = Archive(String(args[2]))
    var labels = Labels(String(args[4]), String(args[5]), String(args[6]))
    var lines: List[String]
    if library == "aws-lc":
        lines = aws_lc(arc, labels)
    elif library == "s2n-tls":
        lines = s2n_tls(arc, labels)
    else:
        print("gen: unknown library " + library + " (aws-lc | s2n-tls)")
        exit(2)
        return
    var text = join(lines, "\n") + "\n"
    with open(String(args[3]), "w") as f:
        f.write(text)
