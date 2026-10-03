# =============================================================================
# src/kci_contract/verbs.mojo -- the verbs a result document names, and the
#   kinds of action a stage holds.
# =============================================================================
#
#   run        THE driver verb: `kci run --stage S` runs every action of S
#   build      an alias of `run` for a stage whose every action is a BUILD
#   publish    an alias of `run` for a stage whose every action is a PUBLISH
#   stages     prints the machine file's stages (changes nothing)
#   ci-check   checks a CI workflow against the machine file (changes nothing)
#
# An action of a stage is a BUILD, a PUBLISH or a DEPLOY. DEPLOY is reserved:
# the word exists so adding its body later is additive; nothing runs one yet.
#
# The spellings are v1 placeholders a design revision may rename; they are
# spelled here only.
# Pure functions over owned values; no pointer.
# =============================================================================

comptime VERB_RUN: String = "run"
comptime VERB_BUILD: String = "build"
comptime VERB_PUBLISH: String = "publish"
comptime VERB_STAGES: String = "stages"
comptime VERB_CI_CHECK: String = "ci-check"

comptime ACTION_BUILD: String = "BUILD"
comptime ACTION_PUBLISH: String = "PUBLISH"
comptime ACTION_DEPLOY: String = "DEPLOY"


def all_verbs() -> List[String]:
    var out = List[String]()
    out.append(String(VERB_RUN))
    out.append(String(VERB_BUILD))
    out.append(String(VERB_PUBLISH))
    out.append(String(VERB_STAGES))
    out.append(String(VERB_CI_CHECK))
    return out^


def all_action_kinds() -> List[String]:
    var out = List[String]()
    out.append(String(ACTION_BUILD))
    out.append(String(ACTION_PUBLISH))
    out.append(String(ACTION_DEPLOY))
    return out^


def require_verb(word: String) raises:
    var v = all_verbs()
    for i in range(len(v)):
        if v[i] == word:
            return
    raise Error(String("verb '") + word + String("' is not a kci verb"))


def require_action_kind(word: String) raises:
    var v = all_action_kinds()
    for i in range(len(v)):
        if v[i] == word:
            return
    raise Error(String("action kind '") + word + String("' is not BUILD, PUBLISH or DEPLOY"))


def alias_action_kind(verb: String) raises -> String:
    """The one action kind an alias runs (`build` -> BUILD, `publish` ->
    PUBLISH); refuses a verb that is not an alias."""
    if verb == VERB_BUILD:
        return String(ACTION_BUILD)
    if verb == VERB_PUBLISH:
        return String(ACTION_PUBLISH)
    raise Error(String("verb '") + verb + String("' is not an alias of run"))
