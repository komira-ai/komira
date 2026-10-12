# =============================================================================
# src/kci_validate/readme_link.mojo -- the link commands of an installed
#   README: what kci computes from the release, what the README says, and
#   the arguments the README run is given.
# =============================================================================
#
# A `.mojoc` holds no machine code, so a program using a library links every
# native library of the library's closure (docs/design/native_packaging.md,
# "Linking from Mojo"). The packer writes the commands into the packaged
# README as a fenced block `sh komira-link` (tools/build/package/pack/
# readme_link.zig), the README examples tool kci ships parses it (`link`,
# tools/build/readme_examples/link.zig), and the install validation runs the
# README with the block's `mojo run` arguments, never with flags of its own:
# what a user copies is what was run. It also computes the arguments the
# closure needs, from the release alone, and refuses a README whose block
# says anything else, so a block missing an owner's `-l` fails the
# validation (design option (a), slice 10).
#
# WHAT KCI COMPUTES (`closure_link_args`), from each library member's
# metadata.json: its `depends` (the first word of each requirement: the
# library's direct Mojo deps by published name, among others) and its
# `lib_files` (a `link` row `lib/lib<X>.so` is shared library X; a `static`
# row `lib/lib<Y>.a` is static archive Y). The closure of a library is
# itself and every library member its `depends` reach; a requirement naming
# no library member (the compiler, `__glibc`, a codec) is not followed.
#
#   run    -Xlinker -L$CONDA_PREFIX/lib, then -Xlinker -l<X> for every shared
#          library of the closure, dependents first: by rank, highest first
#          (the number of shared libraries in the closure of X's own
#          library, X included: an owner that needs another outranks it),
#          then by name. The order the build writes (tools/build/mojo/
#          native_facts.bzl `readme_link_names`), computed from the same
#          graph.
#   build  the run arguments, then -Xlinker -l<Y> for every static archive
#          of the closure by name, then -Xlinker -rpath -Xlinker
#          $ORIGIN/../lib.
#
# A closure with no native file has no arguments and no block. Equal means
# word for word, in order.
#
# THE ARGUMENTS RUN: the README's `run` words, with the text `$CONDA_PREFIX`
# replaced by the environment's directory (the tool keeps it as written; no
# shell runs, so kci puts in what a shell would); the `build` words the same
# way for the native `built` row (`build_link_args`).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_publish.inputs import LoadedRelease
from kci_release_set.conda_metadata import KIND_LIBRARY, LIB_KIND_LINK, LIB_KIND_STATIC

comptime CONDA_PREFIX_TEXT: String = "$CONDA_PREFIX"
"""How the README's block names the environment."""


@fieldwise_init
struct LinkNode(Copyable, Movable):
    """One library member as the link commands see it: its published `name`,
    the names its `depends` require (first words), and the link names of its
    shared libraries and static archives (from `lib_files`).

    Layout: an owned String and Lists of owned Strings. No pointer field."""

    var name: String
    var depends: List[String]
    var shared: List[String]
    var statics: List[String]


struct LinkArgs(Copyable, Movable):
    """The arguments of the two commands: `run` (between `mojo run` and the
    program) and `build` (between `mojo build` and the program). Both empty:
    no block.

    Layout: two Lists of owned Strings. No pointer field."""

    var run: List[String]
    var build: List[String]

    def __init__(out self):
        self.run = List[String]()
        self.build = List[String]()

    def is_empty(self) -> Bool:
        return len(self.run) == 0 and len(self.build) == 0


def _link_name(path: String, suffix: String) raises -> String:
    """`X` of `lib/lib<X><suffix>`; RAISES on another shape."""
    var head = String("lib/lib")
    if not path.startswith(head) or not path.endswith(suffix) or path.byte_length() <= head.byte_length() + suffix.byte_length():
        raise Error(String("lib_files path '") + path + String("' is not lib/lib<name>") + suffix)
    var name = String(path[byte = head.byte_length() : path.byte_length() - suffix.byte_length()])
    if name.find(String("/")) >= 0:
        raise Error(String("lib_files path '") + path + String("' is not directly under lib/"))
    return name^


def link_nodes(release: LoadedRelease) raises -> List[LinkNode]:
    """A node for every library member of `release` (file header). RAISES on
    a `lib_files` path of another shape."""
    var out = List[LinkNode]()
    for m in range(len(release.members)):
        ref mem = release.members[m]
        if not mem.has_conda or mem.conda.kind != KIND_LIBRARY:
            continue
        var deps = List[String]()
        for d in range(len(mem.conda.depends)):
            var words = mem.conda.depends[d].split(String(" "))
            if len(words) > 0:
                deps.append(String(words[0]))
        var shared = List[String]()
        var statics = List[String]()
        for f in range(len(mem.conda.lib_files)):
            ref row = mem.conda.lib_files[f]
            if row.kind == LIB_KIND_LINK:
                shared.append(_link_name(row.path, String(".so")))
            elif row.kind == LIB_KIND_STATIC:
                statics.append(_link_name(row.path, String(".a")))
        out.append(LinkNode(mem.conda.name.copy(), deps^, shared^, statics^))
    return out^


def _index(nodes: List[LinkNode], name: String) -> Int:
    for i in range(len(nodes)):
        if nodes[i].name == name:
            return i
    return -1


def _closure(nodes: List[LinkNode], root: Int) -> List[Int]:
    """The node indices of `root`'s closure, `root` first."""
    var out = List[Int]()
    out.append(root)
    var k = 0
    while k < len(out):
        ref n = nodes[out[k]]
        for d in range(len(n.depends)):
            var at = _index(nodes, n.depends[d])
            if at < 0:
                continue
            var seen = False
            for s in range(len(out)):
                if out[s] == at:
                    seen = True
            if not seen:
                out.append(at)
        k += 1
    return out^


def _shared_count(nodes: List[LinkNode], members: List[Int]) -> Int:
    var n = 0
    for i in range(len(members)):
        n += len(nodes[members[i]].shared)
    return n


def _before(rank_a: Int, name_a: String, rank_b: Int, name_b: String) -> Bool:
    """Whether (rank_a, name_a) comes first: higher rank, then name."""
    if rank_a != rank_b:
        return rank_a > rank_b
    return name_a < name_b


def closure_link_args(nodes: List[LinkNode], root: String) raises -> LinkArgs:
    """The arguments the closure of library `root` needs (file header).
    RAISES when `root` is not a node."""
    var r = _index(nodes, root)
    if r < 0:
        raise Error(String("'") + root + String("' is not a library of the release set"))
    var members = _closure(nodes, r)
    var names = List[String]()
    var ranks = List[Int]()
    var statics = List[String]()
    for i in range(len(members)):
        ref n = nodes[members[i]]
        var rank = _shared_count(nodes, _closure(nodes, members[i]))
        for s in range(len(n.shared)):
            # insertion keeps (rank desc, name asc)
            var at = len(names)
            for k in range(len(names)):
                if _before(rank, n.shared[s], ranks[k], names[k]):
                    at = k
                    break
            names.insert(at, n.shared[s].copy())
            ranks.insert(at, rank)
        for s in range(len(n.statics)):
            var at = len(statics)
            for k in range(len(statics)):
                if n.statics[s] < statics[k]:
                    at = k
                    break
            statics.insert(at, n.statics[s].copy())
    var out = LinkArgs()
    if len(names) == 0 and len(statics) == 0:
        return out^
    out.run.append(String("-Xlinker"))
    out.run.append(String("-L") + String(CONDA_PREFIX_TEXT) + String("/lib"))
    for i in range(len(names)):
        out.run.append(String("-Xlinker"))
        out.run.append(String("-l") + names[i])
    out.build = out.run.copy()
    for i in range(len(statics)):
        out.build.append(String("-Xlinker"))
        out.build.append(String("-l") + statics[i])
    out.build.append(String("-Xlinker"))
    out.build.append(String("-rpath"))
    out.build.append(String("-Xlinker"))
    out.build.append(String("$ORIGIN/../lib"))
    return out^


def parse_link_args(text: String) raises -> LinkArgs:
    """The tool's `link` output: one `run\\t<word>` or `build\\t<word>` line
    per argument. RAISES on any other line."""
    var out = LinkArgs()
    for line in text.split(String("\n")):
        var l = String(line)
        if l.byte_length() == 0:
            continue
        if l.startswith(String("run\t")):
            out.run.append(String(l[byte=4:]))
        elif l.startswith(String("build\t")):
            out.build.append(String(l[byte=6:]))
        else:
            raise Error(String("the README examples tool's link output has the line '") + l + String("'"))
    return out^


def _words(args: List[String]) -> String:
    var s = String("")
    for i in range(len(args)):
        if i > 0:
            s += String(" ")
        s += args[i]
    return s^


def _has(args: List[String], w: String) -> Bool:
    for i in range(len(args)):
        if args[i] == w:
            return True
    return False


def _diff(want: List[String], got: List[String]) -> String:
    """`missing ...; extra ...` of the words, or "" when both hold the same
    words (then only their order differs)."""
    var missing = List[String]()
    var extra = List[String]()
    for i in range(len(want)):
        if not _has(got, want[i]):
            missing.append(want[i].copy())
    for i in range(len(got)):
        if not _has(want, got[i]):
            extra.append(got[i].copy())
    var s = String("")
    if len(missing) > 0:
        s += String("missing ") + _words(missing)
    if len(extra) > 0:
        if s.byte_length() > 0:
            s += String("; ")
        s += String("extra ") + _words(extra)
    if s.byte_length() == 0:
        s = String("the same words in another order")
    return s^


def _same(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _command_refusal(verb: String, want: List[String], got: List[String], readme: String) -> String:
    if _same(want, got):
        return String("")
    return (
        readme + String("'s link block says `mojo ") + verb + String(" ") + _words(got)
        + String("`; the package's closure needs `mojo ") + verb + String(" ") + _words(want)
        + String("` (") + _diff(want, got) + String(")")
    )


def link_refusal(want: LinkArgs, got: LinkArgs, readme: String) -> String:
    """"" when the README's block (`got`) says exactly what the closure
    needs (`want`); otherwise why not, naming `readme` (file header)."""
    if want.is_empty() and got.is_empty():
        return String("")
    if got.is_empty():
        return (
            readme + String(" holds no `sh komira-link` block, but the package's closure links native files:")
            + String(" a user needs `mojo run ") + _words(want.run) + String(" prog.mojo`")
        )
    if want.is_empty():
        return (
            readme + String(" has a `sh komira-link` block (`mojo run ") + _words(got.run)
            + String(" prog.mojo`), but the package's closure links no native file")
        )
    var why = _command_refusal(String("run"), want.run, got.run, readme)
    if why.byte_length() > 0:
        return why^
    return _command_refusal(String("build"), want.build, got.build, readme)


def run_link_args(got: LinkArgs, env_dir: String) -> List[String]:
    """The README's `run` arguments with `$CONDA_PREFIX` replaced by
    `env_dir` (file header)."""
    var out = List[String]()
    for i in range(len(got.run)):
        out.append(got.run[i].replace(String(CONDA_PREFIX_TEXT), env_dir))
    return out^


def build_link_args(got: LinkArgs, env_dir: String) -> List[String]:
    """The README's `build` arguments with `$CONDA_PREFIX` replaced by
    `env_dir` (file header): what the native `built` row
    (native_rows.mojo) gives `mojo build`."""
    var out = List[String]()
    for i in range(len(got.build)):
        out.append(got.build[i].replace(String(CONDA_PREFIX_TEXT), env_dir))
    return out^
