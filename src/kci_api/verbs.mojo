# =============================================================================
# src/kci_api/verbs.mojo -- the verb a result document names, the
#   kinds of step a stage holds, and the kinds of validation a step holds.
# =============================================================================
#
#   run        THE one command: `kci run --stage S` runs every step of S, or
#              the steps and validations `--only` selects (selection.mojo)
#
# kci has exactly one command. There is no other verb and no alias: `kci
# build`, `kci publish`, `kci ci check` and the like are not verbs, so a typed
# `build` is a usage error. Checking a CI workflow against the machine file is
# library code that `kci run` runs at start-up, never a command of its own.
#
# A step of a stage is a BUILD, a PUBLISH or a DEPLOY. DEPLOY is reserved:
# the word exists so adding its body later is additive; nothing runs one yet.
# "Step" is kci's unit of a stage; a Buck2 build action is something else.
#
# A validation belongs to a step and checks what the step produced:
#   CONDA_INSTALL_SMOKE   install the just-published packages from the step's
#                         channel inside a digest-pinned container and run a
#                         smoke program against them
#   CONDA_INSTALL_ENV     install them on this machine, no container, with a
#                         pinned pixi in a scratch directory and a cleared
#                         environment, and run each installed library's README
#                         examples against them
#   DEPLOY_PROBE          run a digest-pinned image against a cell a DEPLOY
#                         step just deployed into; the image writes one result
#                         per expected case and kci decides the verdict
#
# CONDA_INSTALL_SMOKE and CONDA_INSTALL_ENV belong to a PUBLISH step,
# DEPLOY_PROBE to a DEPLOY step (kci_release_machine holds the pairing).
# The machine file reads a DEPLOY_PROBE; no kci runs one yet.
#
# The spellings are spelled here only.
# Pure functions over owned values; no pointer.
# =============================================================================

comptime VERB_RUN: String = "run"

comptime STEP_KIND_BUILD: String = "BUILD"
comptime STEP_KIND_PUBLISH: String = "PUBLISH"
comptime STEP_KIND_DEPLOY: String = "DEPLOY"

comptime VALIDATION_KIND_CONDA_INSTALL_SMOKE: String = "CONDA_INSTALL_SMOKE"
comptime VALIDATION_KIND_CONDA_INSTALL_ENV: String = "CONDA_INSTALL_ENV"
comptime VALIDATION_KIND_DEPLOY_PROBE: String = "DEPLOY_PROBE"


def all_verbs() -> List[String]:
    var out = List[String]()
    out.append(String(VERB_RUN))
    return out^


def all_step_kinds() -> List[String]:
    var out = List[String]()
    out.append(String(STEP_KIND_BUILD))
    out.append(String(STEP_KIND_PUBLISH))
    out.append(String(STEP_KIND_DEPLOY))
    return out^


def require_verb(word: String) raises:
    var v = all_verbs()
    for i in range(len(v)):
        if v[i] == word:
            return
    raise Error(String("verb '") + word + String("' is not a kci verb"))


def require_step_kind(word: String) raises:
    var v = all_step_kinds()
    for i in range(len(v)):
        if v[i] == word:
            return
    raise Error(String("step kind '") + word + String("' is not BUILD, PUBLISH or DEPLOY"))


def all_validation_kinds() -> List[String]:
    var out = List[String]()
    out.append(String(VALIDATION_KIND_CONDA_INSTALL_SMOKE))
    out.append(String(VALIDATION_KIND_CONDA_INSTALL_ENV))
    out.append(String(VALIDATION_KIND_DEPLOY_PROBE))
    return out^


def require_validation_kind(word: String) raises:
    var v = all_validation_kinds()
    for i in range(len(v)):
        if v[i] == word:
            return
    raise Error(
        String("validation kind '") + word + String("' is not CONDA_INSTALL_SMOKE, CONDA_INSTALL_ENV or DEPLOY_PROBE")
    )
