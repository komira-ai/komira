"""Which staged set the README e2e of the release installs from.

`-c komira_release.staged=<which>`:

  assembled (the default)  //release/readme_e2e:staged, written by a build action from the
                           packages the build made. Hermetic: the pull request check builds
                           it, offline.
  stage                    //release/staged_set:set, the files `mopm stage` wrote in the
                           release workflow (job `mopm-stage`), the set that is published.
                           `mopm stage` asks the registry about each version, so it cannot
                           run as a build action.
  beta                     //release/beta_set:set, the files of the beta channel as the job
                           `mopm-e2e-beta` downloaded them after `mopm-publish-beta`: the plan
                           and READMEs `mopm-stage-beta` staged, the `.conda` files the
                           registry serves, each checked against the plan. Its packages carry
                           the beta version of that run, which is not the one of `packages.bzl`:
                           `-c komira_release.beta_version=0.1.<n>` names it, and it is required.

Any other value is an error, so a typo cannot test the wrong set.
"""

_STAGED = {
    "assembled": "//release/readme_e2e:staged",
    "stage": "//release/staged_set:set",
    "beta": "//release/beta_set:set",
}

def _which():
    which = read_config("komira_release", "staged", "assembled")
    if which not in _STAGED:
        fail("komira_release.staged is `{}`: it is one of {}".format(which, sorted(_STAGED.keys())))
    return which

def staged_label():
    """The label of the staged set the e2e targets take as `staged`."""
    return _STAGED[_which()]

def staged_version(release_version):
    """The version the e2e expects of each package: `release_version` (the one of packages.bzl), or
    with the `beta` set the version of the beta run, `-c komira_release.beta_version`."""
    if _which() != "beta":
        return release_version
    beta = read_config("komira_release", "beta_version", "")
    if not beta:
        fail("komira_release.staged is `beta`: -c komira_release.beta_version=<0.1.n> names the version the beta set holds")
    if beta.count(".") != 2:
        fail("komira_release.beta_version is `{}`: it is MAJOR.MINOR.PATCH".format(beta))
    return beta
