# =============================================================================
# src/kci_contract/verbs.mojo -- the verbs a result document names, and the
#   kinds of step a stage holds.
# =============================================================================
#
#   run        THE one verb that runs a stage: `kci run --stage S` runs every
#              step of S, or the steps `--only` selects (selection.mojo)
#   ci-check   checks a CI workflow against the machine file (changes nothing)
#
# There is no other verb and no alias: `kci build`, `kci publish` and the
# like are not verbs, so a typed `build` is a usage error. A utility that is
# not a stage (the deploy side's trust, leaks and cells commands) joins this
# table in the change that builds it.
#
# A step of a stage is a BUILD, a PUBLISH or a DEPLOY. DEPLOY is reserved:
# the word exists so adding its body later is additive; nothing runs one yet.
# "Step" is kci's unit of a stage; a Buck2 build action is something else.
#
# The spellings are spelled here only.
# Pure functions over owned values; no pointer.
# =============================================================================

comptime VERB_RUN: String = "run"
comptime VERB_CI_CHECK: String = "ci-check"

comptime STEP_KIND_BUILD: String = "BUILD"
comptime STEP_KIND_PUBLISH: String = "PUBLISH"
comptime STEP_KIND_DEPLOY: String = "DEPLOY"


def all_verbs() -> List[String]:
    var out = List[String]()
    out.append(String(VERB_RUN))
    out.append(String(VERB_CI_CHECK))
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
