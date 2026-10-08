"""The code deriver: `buck2 uquery` JSON, `mojo doc` JSON, Mojo sources and
Markdown documents in, a `CodeGraph` out.

`CodeGraphBuilder` collects the inputs in any order and `build()` resolves
them together, so the graph depends on the inputs only, not on the order
they were added in. An input added twice with the same content counts
once; one added again with other content is refused (see the last
paragraph). Inputs that each hold one node do not replace it: the edges
they give are all kept. What each input contributes:

- **uquery JSON** (`buck2 uquery <targets> --json --output-attribute
  '^(buck\\.type|deps|srcs|test_srcs|import_name)$'`): a `target` node per
  `mojo_library_rule`, `mojo_binary_rule` and `mojo_test_rule` (other rule
  kinds are skipped), a `file` node per `srcs` and `test_srcs` entry, and
  the `deps`, `srcs` and `tests` edges. A label named only in `deps` gets a
  target node too, imported as its name when no library and no other
  such label has that name. A test target is a `tests` edge
  from each library it lists in `deps`, so a library's tests are its welded
  `test_srcs` and its standalone test targets together.
- **`mojo doc` JSON** of a library (the `mojo_doc_json` rule's output): a
  node per struct, trait, module-level function and `comptime`, and per
  method of a struct or trait; `declares` edges from the module's file and
  from a struct or trait to its methods; `conforms` edges from a struct or
  trait to each trait of its `parentTraits` that is a node of the graph
  (the compiler lists the whole closure: a struct conforming to `B: A`
  conforms to both). Re-exports are not declarations. Private names
  (leading `_`) are not in the JSON, except dunder methods.
- **a Mojo source** of a listed file: `imports` edges to the library
  targets whose packages it imports (a relative import, an import of a
  package that lists the file in `srcs`, and a package no target provides
  give none), and the line of each declaration in it. A method the JSON
  lists but its struct or trait does not write (a lifecycle method of a
  parent trait) keeps line 0.
- **a Markdown document**: a `doc` node, and `governs` edges to the targets
  and files its front matter names.

Every input the deriver cannot place raises an error naming it, rather
than dropping it: a JSON document that is not uquery or `mojo doc` output,
a doc JSON for a label that is no library, a module with no source file, a
source that no target lists, a `governs` entry that names nothing or
several targets or files, two nodes with one id and another kind, file
or text (a symbol two libraries declare in two files), a target listed
twice with a different rule (any `buck.type`, one the deriver skips too),
`srcs`, `test_srcs`, `deps` or import name,
and a source, a document or a label's doc JSON added twice with different
text (compared byte for byte).
"""

from std.collections import Dict
from std.builtin.swap import swap

from komira_json import JsonValue, parse_json_value
from komira_json.value import JSON_ARRAY, JSON_OBJECT, JSON_STRING

from .graph import (
    CodeGraph,
    KgEdge,
    KgNode,
    EDGE_CONFORMS,
    EDGE_DECLARES,
    EDGE_DEPS,
    EDGE_GOVERNS,
    EDGE_IMPORTS,
    EDGE_SRCS,
    EDGE_TESTS,
    NODE_ALIAS,
    NODE_DOC,
    NODE_FILE,
    NODE_FUNCTION,
    NODE_METHOD,
    NODE_STRUCT,
    NODE_TARGET,
    NODE_TRAIT,
)
from .text_scan import declaration_line, imported_modules, read_front_matter, split_lines

comptime _LIBRARY = "mojo_library_rule"
comptime _BINARY = "mojo_binary_rule"
comptime _TEST = "mojo_test_rule"


def _err(msg: String) -> Error:
    return Error("komira_kg_code: " + msg)


def _member(v: JsonValue, key: String) -> Int:
    """The index of member `key` of `v`, or -1. A value that is not an
    object has none: komira_json's parser fills `obj_keys` for objects
    only."""
    for i in range(len(v.obj_keys)):
        if v.obj_keys[i] == key:
            return i
    return -1


def _string_member(v: JsonValue, key: String, what: String) raises -> String:
    """Member `key` of `v` as a string; "" when absent or null."""
    var i = _member(v, key)
    if i < 0 or v.children[i].kind != JSON_STRING:
        if i >= 0 and not v.children[i].is_null():
            raise _err(what + ": `" + key + "` is not a string")
        return String("")
    return v.children[i].text


def _string_list(v: JsonValue, key: String, what: String) raises -> List[String]:
    """Member `key` of `v` as a list of strings; empty when absent or
    null."""
    var out = List[String]()
    var i = _member(v, key)
    if i < 0 or v.children[i].is_null():
        return out^
    ref arr = v.children[i]
    if arr.kind != JSON_ARRAY:
        raise _err(what + ": `" + key + "` is not a list")
    for j in range(len(arr.children)):
        if arr.children[j].kind != JSON_STRING:
            raise _err(what + ": `" + key + "` holds a value that is not a string")
        out.append(arr.children[j].text)
    return out^


def _cell_path(label: String) -> String:
    """`cell//a/b:c` -> `a/b`; `cell//a/b.mojo` -> `a/b.mojo`."""
    var at = label.find("//")
    var rest = String(label[byte = at + 2 : label.byte_length()]) if at >= 0 else label
    var colon = rest.find(":")
    if colon >= 0:
        return String(rest[byte=0:colon])
    return rest^


def _target_name(label: String) -> String:
    var colon = label.rfind(":")
    return String(label[byte = colon + 1 : label.byte_length()])


def _basename(path: String) -> String:
    var slash = path.rfind("/")
    return String(path[byte = slash + 1 : path.byte_length()])


def _dirname(path: String) -> String:
    """The directory of `path`, which holds a `/` (the one caller passes
    a path ending in `/__init__.mojo`)."""
    var slash = path.rfind("/")
    return String(path[byte=0:slash])


@fieldwise_init
struct _Doc(Copyable, Movable):
    var label: String
    var json: String


@fieldwise_init
struct _Text(Copyable, Movable):
    var path: String
    var text: String


@fieldwise_init
struct _Listing(Copyable, Movable):
    """The attributes a target was first listed with, which every later
    listing of it must repeat."""

    var srcs: List[String]
    var test_srcs: List[String]
    var deps: List[String]
    var import_name: String


@fieldwise_init
struct _Decl(Copyable, Movable):
    """A symbol waiting for its line: its node index, the keyword and
    indent of its header, and the node index of its struct or trait (-1 at
    module level)."""

    var node: Int
    var keyword: String
    var name: String
    var indent: Int
    var parent: Int


struct _Graph(Movable):
    """Nodes keyed by id and a set of edges, before ordering."""

    var nodes: List[KgNode]
    var index: Dict[String, Int]
    var edges: List[KgEdge]
    var edge_set: Dict[String, Int]

    def __init__(out self):
        self.nodes = List[KgNode]()
        self.index = Dict[String, Int]()
        self.edges = List[KgEdge]()
        self.edge_set = Dict[String, Int]()

    def has(self, id: String) -> Bool:
        return id in self.index

    def at(self, id: String) raises -> Int:
        return self.index[id]

    def put(mut self, var node: KgNode) raises -> Int:
        """Adds `node` and returns its index. A node equal to one already
        there (a target in two uquery outputs, a symbol two libraries
        declare in one file both list) is kept once; one with the same id
        and another kind, path or text is refused, so no input added
        later replaces one added earlier. The label is not compared: every
        caller derives it from the id and kind. Nor is the line: every node
        is put with line 0 (lines are set after the last symbol is put)."""
        if node.id in self.index:
            var i = self.index[node.id]
            ref old = self.nodes[i]
            if old.kind != node.kind:
                raise _err("two nodes have the id " + node.id + ": a " + old.kind + " and a " + node.kind)
            if old.path != node.path or old.text != node.text:
                raise _err("two different " + node.kind + " nodes have the id " + node.id)
            return i
        var i = len(self.nodes)
        self.index[node.id] = i
        self.nodes.append(node^)
        return i

    def link(mut self, src: String, kind: String, dst: String):
        var key = src + "\x00" + kind + "\x00" + dst
        if key in self.edge_set:
            return
        self.edge_set[key] = len(self.edges)
        self.edges.append(KgEdge(src, kind, dst))


struct CodeGraphBuilder(Movable):
    """Collects the deriver's inputs; `build()` derives the graph (see the
    module header)."""

    var _uquery: List[String]
    var _docs: List[_Doc]
    var _sources: List[_Text]
    var _markdown: List[_Text]

    def __init__(out self):
        self._uquery = List[String]()
        self._docs = List[_Doc]()
        self._sources = List[_Text]()
        self._markdown = List[_Text]()

    def add_uquery_json(mut self, text: String):
        """One `buck2 uquery --json` output (see the module header for the
        attributes it must carry)."""
        self._uquery.append(text)

    def add_mojo_doc_json(mut self, label: String, text: String):
        """The `mojo doc` JSON of the library target `label`."""
        self._docs.append(_Doc(label, text))

    def add_source(mut self, file_id: String, text: String):
        """The text of the Mojo source `file_id`, as the uquery output names
        it (`cell//path/to/file.mojo`)."""
        self._sources.append(_Text(file_id, text))

    def add_markdown(mut self, path: String, text: String):
        """A Markdown document; `path` is its node id and path."""
        self._markdown.append(_Text(path, text))

    def build(self) raises -> CodeGraph:
        """Derives the graph from everything added."""
        var g = _Graph()
        # Library import name -> target label.
        var import_names = Dict[String, String]()
        # Library label -> its srcs.
        var lib_srcs = Dict[String, List[String]]()
        # Target label -> the `buck.type` it was first listed with, for
        # every rule, read or skipped.
        var rules = Dict[String, String]()
        # Target label -> the attributes it was first listed with.
        var listed = Dict[String, _Listing]()
        # File id -> labels listing it in srcs.
        var src_owners = Dict[String, List[String]]()
        var stubs = List[String]()
        var test_targets = List[KgEdge]()
        for q in range(len(self._uquery)):
            _read_uquery(self._uquery[q], g, import_names, lib_srcs, rules, listed, src_owners, stubs, test_targets)
        for i in range(len(test_targets)):
            if test_targets[i].src in lib_srcs:
                g.link(test_targets[i].src, EDGE_TESTS, test_targets[i].dst)
        # A stub imports as its target name, unless a library has that
        # import name or two stubs share it (then neither has one, so the
        # graph does not depend on which uquery output came first).
        var stub_names = Dict[String, String]()
        var shared = Dict[String, Bool]()
        for s in range(len(stubs)):
            if not g.has(stubs[s]):
                _ = g.put(KgNode(stubs[s], NODE_TARGET, _target_name(stubs[s]), _cell_path(stubs[s]), 0, String("")))
                var name = _target_name(stubs[s])
                if name in stub_names:
                    shared[name] = True
                else:
                    stub_names[name] = stubs[s]
        for entry in stub_names.items():
            if entry.key not in shared and entry.key not in import_names:
                import_names[entry.key] = entry.value

        var source_lines = Dict[String, List[String]]()
        var source_texts = Dict[String, String]()
        for i in range(len(self._sources)):
            ref src = self._sources[i]
            if not g.has(src.path) or g.nodes[g.at(src.path)].kind != NODE_FILE:
                raise _err("source " + src.path + " is in no target's srcs or test_srcs")
            if src.path in source_texts:
                if source_texts[src.path] != src.text:
                    raise _err("source " + src.path + " is added twice with different text")
                continue
            source_texts[src.path] = src.text
            source_lines[src.path] = split_lines(src.text)

        var conforms = List[KgEdge]()
        var decls = Dict[String, List[_Decl]]()
        var doc_texts = Dict[String, String]()
        for d in range(len(self._docs)):
            ref doc = self._docs[d]
            if doc.label not in lib_srcs:
                raise _err("mojo doc JSON for " + doc.label + ", which the uquery output has no mojo_library for")
            if doc.label in doc_texts:
                if doc_texts[doc.label] != doc.json:
                    raise _err("mojo doc JSON for " + doc.label + " is added twice with different text")
                continue
            doc_texts[doc.label] = doc.json
            _read_doc(doc.label, doc.json, lib_srcs[doc.label], g, conforms, decls)
        for i in range(len(conforms)):
            if g.has(conforms[i].dst):
                g.link(conforms[i].src, EDGE_CONFORMS, conforms[i].dst)

        for entry in decls.items():
            if entry.key not in source_lines:
                continue
            ref lines = source_lines[entry.key]
            ref ds = entry.value
            for k in range(len(ds)):
                var after = 0
                if ds[k].parent >= 0:
                    after = g.nodes[ds[k].parent].line
                    if after == 0:
                        continue
                g.nodes[ds[k].node].line = declaration_line(lines, ds[k].keyword, ds[k].name, ds[k].indent, after)

        for i in range(len(self._sources)):
            ref src = self._sources[i]
            var mods = imported_modules(src.text)
            for m in range(len(mods)):
                if mods[m].startswith("."):
                    continue
                var dot = mods[m].find(".")
                var top = mods[m] if dot < 0 else String(mods[m][byte=0:dot])
                if top not in import_names:
                    continue
                var lib = import_names[top]
                var own = False
                if src.path in src_owners:
                    ref owners = src_owners[src.path]
                    for o in range(len(owners)):
                        if owners[o] == lib:
                            own = True
                if not own:
                    g.link(src.path, EDGE_IMPORTS, lib)

        var markdown_texts = Dict[String, String]()
        for i in range(len(self._markdown)):
            ref md = self._markdown[i]
            if md.path in markdown_texts:
                if markdown_texts[md.path] != md.text:
                    raise _err("document " + md.path + " is added twice with different text")
                continue
            markdown_texts[md.path] = md.text
            _read_markdown(md.path, md.text, g)

        var nodes = List[KgNode]()
        var edges = List[KgEdge]()
        swap(nodes, g.nodes)
        swap(edges, g.edges)
        return CodeGraph(nodes^, edges^)


def _read_uquery(
    text: String,
    mut g: _Graph,
    mut import_names: Dict[String, String],
    mut lib_srcs: Dict[String, List[String]],
    mut rules: Dict[String, String],
    mut listed: Dict[String, _Listing],
    mut src_owners: Dict[String, List[String]],
    mut stubs: List[String],
    mut tests: List[KgEdge],
) raises:
    var root = parse_json_value(text)
    if root.kind != JSON_OBJECT:
        raise _err("the uquery JSON is not an object of targets")
    for t in range(len(root.obj_keys)):
        var label = root.obj_keys[t]
        ref attrs = root.children[t]
        if attrs.kind != JSON_OBJECT:
            raise _err("uquery JSON: " + label + " is not an object of attributes")
        if _member(attrs, "buck.type") < 0:
            raise _err("uquery JSON: " + label + " has no `buck.type`; run uquery with --output-attribute")
        var rule = _string_member(attrs, "buck.type", label)
        # The rule is recorded before rules the deriver reads no nodes from
        # are skipped, so a label listed with two rules is refused whichever
        # they are.
        if label in rules:
            if rules[label] != rule:
                raise _err("uquery JSON: " + label + " is listed twice with different rules")
        else:
            rules[label] = rule
        if rule != _LIBRARY and rule != _BINARY and rule != _TEST:
            continue
        var short = String(rule[byte = 0 : rule.byte_length() - 5])
        var name = _target_name(label)
        _ = g.put(KgNode(label, NODE_TARGET, name, _cell_path(label), 0, short + " " + name))
        var srcs = _string_list(attrs, "srcs", label)
        var test_srcs = _string_list(attrs, "test_srcs", label)
        var deps = _string_list(attrs, "deps", label)
        var imp = _string_member(attrs, "import_name", label)
        if rule == _LIBRARY and imp.byte_length() == 0:
            imp = name
        if label in listed:
            # Listed by an earlier uquery output: it must agree. Lists
            # compare in order, as uquery prints them in the order the
            # target lists them.
            ref first = listed[label]
            if first.import_name != imp:
                raise _err("uquery JSON: " + label + " is listed twice with different import names")
            if not _same_strings(first.srcs, srcs):
                raise _err("uquery JSON: " + label + " is listed twice with different srcs")
            if not _same_strings(first.test_srcs, test_srcs):
                raise _err("uquery JSON: " + label + " is listed twice with different test_srcs")
            if not _same_strings(first.deps, deps):
                raise _err("uquery JSON: " + label + " is listed twice with different deps")
            continue
        listed[label] = _Listing(srcs.copy(), test_srcs.copy(), deps.copy(), imp)
        for s in range(len(srcs)):
            _put_file(g, srcs[s])
            g.link(label, EDGE_SRCS, srcs[s])
            if srcs[s] not in src_owners:
                src_owners[srcs[s]] = List[String]()
            src_owners[srcs[s]].append(label)
        for s in range(len(test_srcs)):
            _put_file(g, test_srcs[s])
            g.link(label, EDGE_TESTS, test_srcs[s])
        for s in range(len(deps)):
            g.link(label, EDGE_DEPS, deps[s])
            stubs.append(deps[s])
            if rule == _TEST:
                tests.append(KgEdge(deps[s], EDGE_TESTS, label))
        if rule == _LIBRARY:
            if imp in import_names:
                raise _err("uquery JSON: " + label + " and " + import_names[imp] + " both import as `" + imp + "`")
            import_names[imp] = label
            lib_srcs[label] = srcs^


def _same_strings(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _put_file(mut g: _Graph, id: String) raises:
    if not g.has(id):
        var path = _cell_path(id)
        _ = g.put(KgNode(id, NODE_FILE, _basename(path), path, 0, String("")))


def _trait_id(path: String) -> String:
    """A `parentTraits` path (`/pkg/module/Trait`) as a symbol id
    (`pkg.module.Trait`)."""
    var p = String(path[byte = 1 : path.byte_length()]) if path.startswith("/") else path
    return p.replace("/", ".")


def _first_overload(func: JsonValue, what: String) raises -> Int:
    var i = _member(func, "overloads")
    if i < 0 or func.children[i].kind != JSON_ARRAY or len(func.children[i].children) == 0:
        raise _err(what + ": a function with no `overloads`")
    return i


def _symbol_text(signature: String, summary: String) -> String:
    if signature.byte_length() == 0:
        return summary
    if summary.byte_length() == 0:
        return signature
    return signature + "\n" + summary


def _read_functions(
    owner: JsonValue,
    prefix: String,
    kind: String,
    file_id: String,
    path: String,
    parent: Int,
    mut g: _Graph,
    mut out_decls: List[_Decl],
) raises:
    """The functions of a module (`kind` function) or of a struct or trait
    (`kind` method, `parent` its node)."""
    var fi = _member(owner, "functions")
    if fi < 0:
        return
    ref fns = owner.children[fi]
    for f in range(len(fns.children)):
        ref func = fns.children[f]
        var name = _string_member(func, "name", prefix)
        var oi = _first_overload(func, prefix + "." + name)
        ref first = func.children[oi].children[0]
        var id = prefix + "." + name
        var text = _symbol_text(_string_member(first, "signature", id), _string_member(first, "summary", id))
        var n = g.put(KgNode(id, kind, name, path, 0, text^))
        var src = file_id if parent < 0 else g.nodes[parent].id
        g.link(src, EDGE_DECLARES, id)
        out_decls.append(_Decl(n, String("def"), name, 0 if parent < 0 else 4, parent))


def _read_module(
    mod: JsonValue, prefix: String, file_id: String, mut g: _Graph, mut conforms: List[KgEdge], mut out_decls: List[_Decl]
) raises:
    var path = _cell_path(file_id)
    _read_functions(mod, prefix, NODE_FUNCTION, file_id, path, -1, g, out_decls)
    var ai = _member(mod, "aliases")
    if ai >= 0:
        ref aliases = mod.children[ai]
        for a in range(len(aliases.children)):
            ref al = aliases.children[a]
            var name = _string_member(al, "name", prefix)
            var id = prefix + "." + name
            var text = _symbol_text(_string_member(al, "signature", id), _string_member(al, "summary", id))
            var n = g.put(KgNode(id, NODE_ALIAS, name, path, 0, text^))
            g.link(file_id, EDGE_DECLARES, id)
            out_decls.append(_Decl(n, String("comptime"), name, 0, -1))
    for which in range(2):
        var key = String("structs") if which == 0 else String("traits")
        var kind = String(NODE_STRUCT) if which == 0 else String(NODE_TRAIT)
        var si = _member(mod, key)
        if si < 0:
            continue
        ref items = mod.children[si]
        for s in range(len(items.children)):
            ref st = items.children[s]
            var name = _string_member(st, "name", prefix)
            var id = prefix + "." + name
            var text = _symbol_text(_string_member(st, "signature", id), _string_member(st, "summary", id))
            var n = g.put(KgNode(id, kind, name, path, 0, text^))
            g.link(file_id, EDGE_DECLARES, id)
            out_decls.append(_Decl(n, kind, name, 0, -1))
            var pi = _member(st, "parentTraits")
            if pi >= 0:
                ref parents = st.children[pi]
                for p in range(len(parents.children)):
                    var tp = _string_member(parents.children[p], "path", id)
                    if tp.byte_length() > 0:
                        conforms.append(KgEdge(id, EDGE_CONFORMS, _trait_id(tp)))
            _read_functions(st, id, NODE_METHOD, file_id, path, n, g, out_decls)


def _read_package(
    pkg: JsonValue,
    prefix: String,
    dir_id: String,
    label: String,
    srcs: List[String],
    mut g: _Graph,
    mut conforms: List[KgEdge],
    mut decls: Dict[String, List[_Decl]],
) raises:
    var mi = _member(pkg, "modules")
    if mi >= 0:
        ref mods = pkg.children[mi]
        for m in range(len(mods.children)):
            ref mod = mods.children[m]
            var mname = _string_member(mod, "name", prefix)
            var file_id = dir_id + "/" + mname + ".mojo"
            var listed = False
            for s in range(len(srcs)):
                if srcs[s] == file_id:
                    listed = True
            if not listed:
                raise _err(label + ": module " + prefix + "." + mname + " has no source " + file_id + " in the target's srcs")
            # `__init__` declarations are the package's own.
            var mprefix = prefix if mname == "__init__" else prefix + "." + mname
            if file_id not in decls:
                decls[file_id] = List[_Decl]()
            _read_module(mod, mprefix, file_id, g, conforms, decls[file_id])
    var pi = _member(pkg, "packages")
    if pi >= 0:
        ref subs = pkg.children[pi]
        for p in range(len(subs.children)):
            ref sub = subs.children[p]
            var sname = _string_member(sub, "name", prefix)
            _read_package(sub, prefix + "." + sname, dir_id + "/" + sname, label, srcs, g, conforms, decls)


def _read_doc(
    label: String,
    text: String,
    srcs: List[String],
    mut g: _Graph,
    mut conforms: List[KgEdge],
    mut decls: Dict[String, List[_Decl]],
) raises:
    var root = parse_json_value(text)
    var di = _member(root, "decl")
    if di < 0 or _string_member(root.children[di], "kind", label) != "package":
        raise _err(label + ": the doc JSON has no `decl` package; is it `mojo doc` output?")
    ref decl = root.children[di]
    var pkg_name = _string_member(decl, "name", label)
    # The package root: the directory of the shallowest __init__.mojo.
    var dir_id = String("")
    var best = -1
    for s in range(len(srcs)):
        if srcs[s].endswith("/__init__.mojo"):
            var depth = len(srcs[s].split("/"))
            if best < 0 or depth < best:
                best = depth
                dir_id = _dirname(srcs[s])
    if best < 0:
        raise _err(label + ": the target's srcs hold no __init__.mojo")
    _read_package(decl, pkg_name, dir_id, label, srcs, g, conforms, decls)


def _read_markdown(path: String, text: String, mut g: _Graph) raises:
    var fm = read_front_matter(path, text)
    var title = fm.title
    if title.byte_length() == 0:
        var lines = split_lines(text)
        for i in range(len(lines)):
            if lines[i].startswith("# "):
                title = String(lines[i][byte = 2 : lines[i].byte_length()])
                break
    _ = g.put(KgNode(path, NODE_DOC, _basename(path), path, 0, title))
    for i in range(len(fm.governs)):
        var want = fm.governs[i]
        var found = String("")
        var hits = 0
        for n in range(len(g.nodes)):
            ref node = g.nodes[n]
            var hit = False
            if node.kind == NODE_TARGET:
                hit = node.id == want or (want.startswith("//") and node.id.endswith(want))
            elif node.kind == NODE_FILE:
                hit = node.id == want or node.path == want
            if hit:
                hits += 1
                found = node.id
        if hits == 0:
            raise _err(path + ": governs `" + want + "`, which names no target or file of the graph")
        if hits > 1:
            raise _err(path + ": governs `" + want + "`, which names " + String(hits) + " targets or files; give the cell")
        g.link(path, EDGE_GOVERNS, found)
