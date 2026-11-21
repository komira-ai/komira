"""The CPU-level variants of libkomira a platform row ships: their vocabulary, their checks and the `VARIANTS` manifest.

A variant is one link of libkomira for one `target_cpu` (docs/design/isa_variants.md). Each row of
the platform table (table.bzl) lists its shipped variants in `isa_variants`, lowest first:

    isa_variant(name, target_cpu, requires, target_features = [])

`requires` is the CPU features a machine must list for the variant to run there, in the spelling of
Linux's /proc/cpuinfo (`flags` on x86, `Features` on arm64), sorted. The row is the only place they
are written down: the toolchains (tools/build/toolchains/defs.bzl), the link targets
(src/so/BUCK) and the manifest below are all read from it.

The first variant is the row's floor: its library keeps the plain path `<dir>/libkomira.so`, and
every C object of the row is compiled for its CPU, since the native owners are shared by every
variant. Each other variant is at `<dir>/variants/<name>/<file>`.

`variant_refusals(name, row)` is every way a row's list is wrong, as sentences;
table.bzl's completeness check adds them to its own.
"""

# The characters of a variant name: it is a directory name of the native directory and a field of
# the manifest, so a plain path segment without whitespace.
_NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789-_."

# The characters of a `requires` word: a /proc/cpuinfo flag (`sse4_2`, `lahf_lm`, `asimddp`).
_FEATURE_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"

_FIELDS = ["name", "requires", "target_cpu", "target_features"]

def isa_variant(name, target_cpu, requires, target_features = []):
    """One variant of a row: a link of libkomira for `target_cpu` (and `target_features`), loaded on a CPU listing every word of `requires`."""
    return {"name": name, "requires": requires, "target_cpu": target_cpu, "target_features": target_features}

def _only(s, chars):
    for c in s.elems():
        if c not in chars:
            return False
    return True

def _is_string_list(v):
    return type(v) == "list" and not [x for x in v if type(x) != "string"]

def _variant_refusals(row_name, i, v):
    where = "row {}: isa_variants[{}]".format(row_name, i)
    if type(v) != "dict" or sorted(v.keys()) != _FIELDS:
        return ["{} is not an isa_variant(...)".format(where)]
    out = []
    name = v["name"]
    if type(name) != "string" or not name or not _only(name, _NAME_CHARS) or name in (".", ".."):
        out.append("{}: name {} is not a plain path segment of [a-z0-9._-]".format(where, repr(name)))
    if type(v["target_cpu"]) != "string" or not v["target_cpu"]:
        out.append("{}: `target_cpu` is empty".format(where))
    if not _is_string_list(v["target_features"]):
        out.append("{}: `target_features` is not a list of strings".format(where))
    req = v["requires"]
    if not _is_string_list(req) or req != sorted(req) or len({r: 1 for r in req}) != len(req):
        out.append("{}: `requires` must be a sorted list of strings without duplicates".format(where))
    else:
        for r in req:
            if not r or not _only(r, _FEATURE_CHARS):
                out.append("{}: `requires` word {} is not a /proc/cpuinfo flag of [a-z0-9_]".format(where, repr(r)))
    return out

def variant_refusals(row_name, row):
    """Every way the `isa_variants` of `row` is wrong, as sentences naming the row; [] when it is right."""
    variants = row["isa_variants"]
    if type(variants) != "list" or not variants:
        return ["row {}: `isa_variants` is empty: a row ships at least its floor".format(row_name)]
    out = []
    for i, v in enumerate(variants):
        out.extend(_variant_refusals(row_name, i, v))
    if out:
        return out
    names = {}
    for i, v in enumerate(variants):
        if v["name"] in names:
            out.append("row {}: two variants are named `{}`".format(row_name, v["name"]))
        names[v["name"]] = i
        if i > 0:
            below = variants[i - 1]
            lacking = [r for r in below["requires"] if r not in v["requires"]]
            if lacking or len(v["requires"]) == len(below["requires"]):
                out.append("row {}: variant `{}` does not require every feature of `{}` and more (lacks {})".format(
                    row_name,
                    v["name"],
                    below["name"],
                    " ".join(lacking) or "nothing, and adds nothing",
                ))
    defaults = [v for v in variants if v["target_cpu"] == row["target_cpu"] and v["target_features"] == row["target_features"]]
    if len(defaults) > 1:
        out.append("row {}: variants {} are all the row's own build".format(row_name, ", ".join([v["name"] for v in defaults])))
    if not defaults:
        out.append("row {}: no variant is the row's own build (target_cpu `{}`, target_features {}): the tested build must ship".format(
            row_name,
            row["target_cpu"],
            row["target_features"],
        ))

    # A variant other than the row's own build gets a toolchain of its own that sets only its
    # `target_cpu` (tools/build/toolchains/defs.bzl): no Mojo compile passes features yet, so a
    # variant that needs them would silently be built without.
    for v in extra_variants(row):
        if v["target_features"]:
            out.append("row {}: variant `{}` sets target_features {}, which no variant toolchain passes to the compile yet".format(
                row_name,
                v["name"],
                v["target_features"],
            ))
    return out

def variant_libs_refusals(row_name, row, names):
    """[] if `names` (the variant names a set of links is keyed by) are exactly the variants of `row`; else the sentence saying how they differ."""
    want = sorted([v["name"] for v in row["isa_variants"]])
    if sorted(names) == want:
        return []
    return ["the links are for the variants {}, but row {} ships {}".format(sorted(names), row_name, want)]

def floor_variant(row):
    """The lowest variant of `row`: the one at the plain path, and the CPU every C object of the row is compiled for."""
    return row["isa_variants"][0]

def extra_variants(row):
    """The variants of `row` other than its own build (`target_cpu`): the ones that need their own toolchain and link."""
    return [v for v in row["isa_variants"] if v["target_cpu"] != row["target_cpu"] or v["target_features"] != row["target_features"]]

def variant_path(row, v, file_name):
    """Where variant `v` of `row` is in the native directory: `file_name` for the floor, `variants/<name>/<file_name>` for the others."""
    if v["name"] == floor_variant(row)["name"]:
        return file_name
    return "variants/{}/{}".format(v["name"], file_name)

def variants_manifest(row, file_name):
    """The text of the native directory's `VARIANTS`: one line per variant of `row`, lowest first, of the name, the path of its `file_name` and its `requires`, separated by tabs."""
    return "".join([
        "{}\t{}\t{}\n".format(v["name"], variant_path(row, v, file_name), " ".join(v["requires"]))
        for v in row["isa_variants"]
    ])

def variant_label_name(v):
    """`v`'s name as a target-name suffix: `x86-64-v2` -> `x86_64_v2`."""
    return v["name"].replace("-", "_").replace(".", "_")
