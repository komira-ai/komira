"""Which staged set the README e2e of the release installs from.

`-c komira_release.staged=<which>`:

  assembled (the default)  //release/readme_e2e:staged, written by a build action from the
                           packages the build made. Hermetic: the pull request check builds
                           it, offline.
  stage                    //release/staged_set:set, the files `mopm stage` wrote in the
                           release workflow (job `mopm-stage`), the set that is published.
                           `mopm stage` asks the registry about each version, so it cannot
                           run as a build action.

Any other value is an error, so a typo cannot test the wrong set.
"""

_STAGED = {
    "assembled": "//release/readme_e2e:staged",
    "stage": "//release/staged_set:set",
}

def staged_label():
    """The label of the staged set the e2e targets take as `staged`."""
    which = read_config("komira_release", "staged", "assembled")
    if which not in _STAGED:
        fail("komira_release.staged is `{}`: it is one of {}".format(which, sorted(_STAGED.keys())))
    return _STAGED[which]
