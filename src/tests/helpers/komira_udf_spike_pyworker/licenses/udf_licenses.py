"""The licences of this package's own wheels (third_party/python/pins.bzl,
WHEELS_UDF_PYTHON) are the ones pinned, none is the AGPL, and every file in
them that names a GNU licence is a reviewed entry.

Arguments: `<distribution>=<SPDX expression>` for each of those wheels, and
`allow=<distribution>:<path>` for each reviewed file (third_party/python/
README.md, Licences). Distributions installed as their dependencies but not
named (numpy, from the shared closure) are not this test's.
"""

import importlib.metadata
import os
import re
import sys

LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|notice)([._-].*)?$", re.IGNORECASE)
AGPL = re.compile(r"GNU AFFERO GENERAL PUBLIC LICENSE|\bAGPL-[0-9]")
GPL = re.compile(r"GNU\s+(LESSER\s+|LIBRARY\s+|AFFERO\s+)?GENERAL\s+PUBLIC\s+LICENSE|\b(L?GPL)-[0-9]", re.IGNORECASE)
GPL_LIBS = re.compile(r"^lib(gfortran|quadmath|readline|gdbm)\b")


def normalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def hits_in(owner, root, hits, agpl):
    for d, _, files in os.walk(root):
        in_licenses = os.sep + "licenses" in d and ".dist-info" in d
        for f in files:
            rel = os.path.relpath(os.path.join(d, f), root)
            if GPL_LIBS.match(f) and ".so" in f:
                hits.add("{}:{}".format(owner, rel))
            if not (in_licenses or LICENCE_FILE.match(f)):
                continue
            with open(os.path.join(d, f), "rb") as fh:
                text = fh.read().decode("utf-8", "replace")
            if AGPL.search(text):
                agpl.append("{}:{}".format(owner, rel))
            elif GPL.search(text):
                hits.add("{}:{}".format(owner, rel))


def main(args):
    assert GPL.search("GNU General\nPublic License") and not GPL.search("GPL-compatible")
    assert AGPL.search("GNU AFFERO GENERAL PUBLIC LICENSE") and not AGPL.search("the GNU Affero General Public License")
    pins, allow = {}, set()
    for a in args:
        key, _, value = a.partition("=")
        if key == "allow":
            allow.add(value)
        else:
            pins[normalize(key)] = value
    hits, agpl, bad, seen = set(), [], [], set()
    for dist in importlib.metadata.distributions():
        name = normalize(dist.metadata["Name"])
        if name not in pins:
            continue
        seen.add(name)
        own = {e for e in allow if e.startswith(dist.metadata["Name"] + ":") or e.startswith(name + ":")}
        expr = dist.metadata.get("License-Expression")
        if expr is not None and expr != pins[name]:
            bad.append("{} declares License-Expression '{}', the pin records '{}'".format(name, expr, pins[name]))
        hits_in(dist.metadata["Name"], str(dist.locate_file("")), hits, agpl)
        print("{} {}: {}".format(name, dist.version, pins[name]), len(own), "reviewed")
    for name in sorted(set(pins) - seen):
        bad.append("pinned but not installed: " + name)
    bad += ["{} names the GNU Affero GPL".format(h) for h in agpl]
    bad += ["{} names a GNU licence and is not an allow entry".format(h) for h in sorted(hits - allow)]
    bad += ["allow entry {} matches no file naming a GNU licence".format(h) for h in sorted(allow - hits)]
    for h in sorted(hits & allow):
        print("reviewed:", h)
    assert not bad, "\n".join(bad)


main(sys.argv[1:])
