"""The komira wheel after an upgrade from the previous release: what `pip
install --upgrade komira` leaves in a user's environment (python/BUCK,
wheel_install_test with `upgrade`).

    <prefix>/bin/python3.<minor> -I test_upgrade.py --site <dir>
        --removed <path>... --expect-removed <path>... --installed-script
        <test_installed.py> [the flags of test_installed.py]

Run by wheel_install_run.py, which installed the previous release and then
the current one into `--site`, uninstalling the first as pip does, and gives
`--removed` for each file the previous release had that the current one lacks.
Then, in order:

- the site directory holds the dist-info of the current release (`--version`)
  and none of any other release of komira (other distributions, such as the
  external flavour's Modular wheels, are not looked at here);
- the upgrade removed at least the files `--expect-removed` names, so the
  previous release did carry files the current one does not (an upgrade that
  has nothing to remove proves nothing about removal), and every file it
  removed is gone from `--site`;
- everything test_installed.py holds of a fresh install holds here: the
  upgraded environment is the one `pip install komira` makes (the current
  release imports, loads libkomira at the ABI version of the golden, serves a
  Parquet file and a plan, maps its libraries from `<site>/komira/_lib`, and
  the environment holds nothing of Modular's).

Any failure raises; its last traceback line is what a refusing case names.
"""

import importlib.util
import os
import sys

_OWN = ("--removed", "--expect-removed", "--installed-script")


def split(argv):
    """(this script's flags as {flag: [values]}, the other flags in order)."""
    own = {k: [] for k in _OWN}
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] in own:
            if i + 1 >= len(argv):
                raise SystemExit("test_upgrade: flag {} needs a value".format(argv[i]))
            own[argv[i]].append(argv[i + 1])
        else:
            rest.append(argv[i])
            if i + 1 < len(argv):
                rest.append(argv[i + 1])
        i += 2
    return own, rest


def value_of(argv, flag):
    for i in range(0, len(argv) - 1, 2):
        if argv[i] == flag:
            return argv[i + 1]
    raise SystemExit("test_upgrade: {} is required".format(flag))


def load_script(path):
    spec = importlib.util.spec_from_file_location("test_installed", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv):
    own, rest = split(argv)
    if len(own["--installed-script"]) != 1:
        raise SystemExit("test_upgrade: --installed-script is required once")
    site = os.path.realpath(value_of(rest, "--site"))
    version = value_of(rest, "--version")

    infos = sorted(e for e in os.listdir(site) if e.endswith(".dist-info") and e.startswith("komira-"))
    want = ["komira-{}.dist-info".format(version)]
    assert infos == want, "the site holds {}, the upgrade should leave only {}".format(", ".join(infos) or "no dist-info", want[0])

    removed = own["--removed"]
    missing = sorted(set(own["--expect-removed"]) - set(removed))
    assert not missing, "the upgrade did not remove {}: the previous release does not carry it".format(", ".join(missing))
    left = sorted(p for p in removed if os.path.lexists(os.path.join(site, p)))
    assert not left, "the upgrade left {} of the previous release".format(", ".join(left))

    load_script(own["--installed-script"][0]).main(rest)
    print("upgrade: {} replaced the previous release, {} files of it removed".format(want[0], len(removed)))


if __name__ == "__main__":
    main(sys.argv[1:])
