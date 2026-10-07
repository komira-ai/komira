"""The licences of the hermetic Python are the ones recorded, and none is the AGPL or an unreviewed GPL.

Arguments: `<distribution>=<SPDX expression>` for the interpreter (`cpython`)
and every pinned wheel (third_party/python/pins.bzl), and `allow=<owner>:<path>`
for each reviewed file that names a GNU licence (third_party/python/README.md,
Licences). Fails unless the patterns pass their own cases (check_patterns),
and:

- every installed distribution is pinned, and one whose METADATA declares a
  `License-Expression` declares exactly the pinned one;
- no licence file (a file named LICENSE, LICENCE, COPYING or NOTICE, in any
  case and with any suffix, or one under a `.dist-info/licenses/` directory)
  of the interpreter or of any wheel is the GNU Affero GPL (its upper-case
  title, or an `AGPL-` SPDX identifier);
- every licence file naming the GNU GPL, LGPL, Library GPL or Affero GPL,
  and every bundled library known to be under one (libgfortran, libquadmath,
  libreadline, libgdbm), is an `allow` entry, and every `allow` entry is one
  of them.

`<owner>` is a distribution name or `cpython`; `<path>` is relative to the
wheel's install directory or to the interpreter's root.
"""

import importlib.metadata
import os
import re
import sys

LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|notice)([._-].*)?$", re.IGNORECASE)
# The AGPL itself: its title as the licence text spells it (upper case), or
# its SPDX identifier. Other licence texts name it in mixed case (the GPL-3.0
# section 13, the MPL-2.0 definition of a Secondary License); those are
# GPL hits, reviewed as such.
AGPL = re.compile(r"GNU AFFERO GENERAL PUBLIC LICENSE|\bAGPL-[0-9]")
GPL = re.compile(r"GNU\s+(LESSER\s+|LIBRARY\s+|AFFERO\s+)?GENERAL\s+PUBLIC\s+LICENSE|\b(L?GPL)-[0-9]", re.IGNORECASE)
GPL_LIBS = re.compile(r"^lib(gfortran|quadmath|readline|gdbm)\b")


def normalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def licence_files(root):
    for d, _, files in os.walk(root):
        in_licenses = os.sep + "licenses" in d and ".dist-info" in d
        for f in files:
            if in_licenses or LICENCE_FILE.match(f):
                yield os.path.relpath(os.path.join(d, f), root)


def gpl_libs(root):
    for d, _, files in os.walk(root):
        for f in files:
            if GPL_LIBS.match(f) and ".so" in f:
                yield os.path.relpath(os.path.join(d, f), root)


# The text around a match, on one line, for the failure message.
CONTEXT = {}


def _context(text, m):
    return " ".join(text[max(0, m.start() - 80) : m.end() + 40].split())


def scan(owner, root, hits, agpl):
    for rel in sorted(licence_files(root)):
        with open(os.path.join(root, rel), "rb") as f:
            text = f.read().decode("utf-8", "replace")
        a = AGPL.search(text)
        g = GPL.search(text)
        if a:
            agpl.append("{}:{} ({})".format(owner, rel, _context(text, a)))
        elif g:
            key = "{}:{}".format(owner, rel)
            hits.add(key)
            CONTEXT[key] = _context(text, g)
    for rel in gpl_libs(root):
        hits.add("{}:{}".format(owner, rel))


def check_patterns():
    """The patterns tell the AGPL from texts that only name it, and find the GPL family."""
    agpl_title = "                    GNU AFFERO GENERAL PUBLIC LICENSE\n                       Version 3"
    gpl3_s13 = "13. Use with the GNU Affero General Public License."
    mpl_def = "the GNU Lesser General Public License, Version 2.1, the GNU Affero General Public License, Version 3.0"
    assert AGPL.search(agpl_title) and AGPL.search("License: AGPL-3.0-or-later"), "the AGPL pattern misses the AGPL"
    assert not AGPL.search(gpl3_s13) and not AGPL.search(mpl_def), "the AGPL pattern takes a text naming the AGPL for it"
    for text in [gpl3_s13, mpl_def, "GNU General\nPublic License", "GNU LIBRARY GENERAL PUBLIC LICENSE", "SPDX: GPL-2.0-only", "LGPL-2.1-or-later"]:
        assert GPL.search(text), "the GPL pattern misses {!r}".format(text)
    for text in ["GPL-compatible", "MIT License", "Apache License, Version 2.0"]:
        assert not GPL.search(text), "the GPL pattern takes {!r}".format(text)
    assert GPL_LIBS.match("libgfortran-83c28eba-468e71e5.so.5.0.0") and not GPL_LIBS.match("libscipy_openblas64_-f48b354e.so")


def main(args):
    check_patterns()
    pins = {}
    allow = set()
    for a in args:
        key, _, value = a.partition("=")
        if key == "allow":
            allow.add(value)
        else:
            pins[normalize(key)] = value
    hits, agpl, bad = set(), [], []

    scan("cpython", sys.prefix, hits, agpl)
    seen = set()
    for dist in importlib.metadata.distributions():
        name = normalize(dist.metadata["Name"])
        root = str(dist.locate_file(""))
        if name in seen:
            bad.append("{} is installed twice".format(name))
        seen.add(name)
        if name not in pins:
            bad.append("{} is installed but not pinned".format(name))
            continue
        expr = dist.metadata.get("License-Expression")
        if expr is not None and expr != pins[name]:
            bad.append("{} declares License-Expression '{}', the pin records '{}'".format(name, expr, pins[name]))
        scan(name, root, hits, agpl)
        print("{} {}: {}".format(name, dist.version, pins[name]))
    missing = sorted(set(pins) - seen - {"cpython"})
    if missing:
        bad.append("pinned but not installed: {}".format(", ".join(missing)))
    for h in agpl:
        bad.append("{} names the GNU Affero GPL".format(h))
    for h in sorted(hits - allow):
        bad.append("{} names a GNU licence and is not an allow entry ({})".format(h, CONTEXT.get(h, "a library known to be under one")))
    for h in sorted(allow - hits):
        bad.append("allow entry {} matches no file naming a GNU licence".format(h))
    for h in sorted(hits & allow):
        print("reviewed:", h)
    assert not bad, "\n".join(bad)


main(sys.argv[1:])
