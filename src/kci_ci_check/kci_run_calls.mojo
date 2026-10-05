# =============================================================================
# src/kci_ci_check/kci_run_calls.mojo -- every `kci run` a `run:` script
#   invokes, and the flags the workflow check reads from it.
# =============================================================================
#
# How `kci run` is found (R5): each `run:` block is split into shell words
# (a line ending in `\` continues; quotes around a word are dropped); an
# invocation is a word in COMMAND position (the first word of a line, or
# right after `;` `&&` `||` `|` `then` `do` `else` `exec` `!`, or after a
# word ending in `;`) whose last `/`-separated part is `kci`, followed by
# the word `run`. So `echo "... kci run ..."` is not one. Its arguments run
# to the end of the line or the next `;` `&&` `||` `|`, and are kept as
# written (unquoted); `--stage`, `--machine`, `--only`, `--summary-file`,
# `--affected-by` and `--release-set-hash` take the next word, or `=<v>`;
# `--channel` is recorded wherever it stands. A GitHub expression
# `${{ ... }}` is one word, whatever spaces it holds.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================


def _words(script: String) -> List[List[String]]:
    """`script` as logical lines of words (file header, R5)."""
    var out = List[List[String]]()
    var parts = script.split(String("\n"))
    var current = String("")
    for i in range(len(parts)):
        var line = String(String(parts[i]).strip())
        if line.endswith(String("\\")):
            current += String(line[byte = 0 : line.byte_length() - 1]) + String(" ")
            continue
        current += line
        var words = List[String]()
        var toks = current.split(String(" "))
        var t = 0
        while t < len(toks):
            var w = String(toks[t])
            t += 1
            if w.byte_length() == 0:
                continue
            # `${{ ... }}` is one word, whatever spaces it holds
            var expr_at = w.find(String("${{"))
            if expr_at >= 0 and w.find(String("}}"), expr_at) < 0:
                while t < len(toks):
                    var more = String(toks[t])
                    t += 1
                    w += String(" ") + more
                    if more.find(String("}}")) >= 0:
                        break
            if w.byte_length() >= 2 and (
                (w.startswith(String("\"")) and w.endswith(String("\"")))
                or (w.startswith(String("'")) and w.endswith(String("'")))
            ):
                var unquoted = String(w[byte = 1 : w.byte_length() - 1])
                w = unquoted^
            words.append(w^)
        out.append(words^)
        current = String("")
    return out^


def _is_kci(word: String) -> Bool:
    var at = word.rfind(String("/"))
    var base = word.copy()
    if at >= 0:
        base = String(word[byte = at + 1 :])
    return base == String("kci")


struct KciRunCall(Copyable, Movable):
    """One `kci run` found in a job: the `--stage` value ("" when absent),
    the `--machine` value (`has_machine` False when absent), whether it
    carries any `--only` and each `--only` value as written (unquoted),
    whether it passes `--summary-file` and `--channel`, the `--affected-by`
    value (`has_affected_by` False when absent), the `--release-set-hash`
    value as written, unquoted (`has_release_set_hash` False when absent),
    and every argument after `run` as written (unquoted).
    Layout: owned Strings, Lists of Strings and Bools. No pointer field."""

    var stage: String
    var machine: String
    var has_machine: Bool
    var has_only: Bool
    var only: List[String]
    var has_summary_file: Bool
    var affected_by: String
    var has_affected_by: Bool
    var release_set_hash: String
    var has_release_set_hash: Bool
    var has_channel: Bool
    var args: List[String]

    def __init__(out self, var stage: String):
        self.stage = stage^
        self.machine = String("")
        self.has_machine = False
        self.has_only = False
        self.only = List[String]()
        self.has_summary_file = False
        self.affected_by = String("")
        self.has_affected_by = False
        self.release_set_hash = String("")
        self.has_release_set_hash = False
        self.has_channel = False
        self.args = List[String]()


def _command_position(w: List[String], j: Int) -> Bool:
    if j == 0:
        return True
    var p = w[j - 1]
    if p.endswith(String(";")):
        return True
    for sep in [";", "&&", "||", "|", "then", "do", "else", "exec", "!"]:
        if p == String(sep):
            return True
    return False


def kci_run_calls(script: String) -> List[KciRunCall]:
    """Every `kci run` invocation in a `run:` script (file header, R5)."""
    var out = List[KciRunCall]()
    var lines = _words(script)
    for i in range(len(lines)):
        ref w = lines[i]
        for j in range(len(w)):
            if not _is_kci(w[j]) or j + 1 >= len(w) or w[j + 1] != String("run"):
                continue
            if not _command_position(w, j):
                continue
            var args = _call_args(w, j + 2)
            var call = KciRunCall(String(""))
            call.args = args.copy()
            var seen_stage = False
            var k = 0
            while k < len(args):
                var a = args[k].copy()
                var value = String("")
                var has_value = False
                var flag = a.copy()
                var eq = a.find(String("="))
                if a.startswith(String("--")) and eq > 0:
                    flag = String(a[byte=0:eq])
                    value = String(a[byte = eq + 1 :])
                    has_value = True
                elif k + 1 < len(args):
                    value = args[k + 1].copy()
                    has_value = True
                if flag == String("--stage") and has_value:
                    if not seen_stage:
                        call.stage = value.copy()
                        seen_stage = True
                elif flag == String("--machine") and has_value:
                    call.machine = value.copy()
                    call.has_machine = True
                elif flag == String("--only"):
                    call.has_only = True
                    if has_value:
                        call.only.append(value.copy())
                elif flag == String("--summary-file") and has_value:
                    call.has_summary_file = True
                elif flag == String("--affected-by"):
                    call.has_affected_by = True
                    if has_value:
                        call.affected_by = value.copy()
                elif flag == String("--release-set-hash"):
                    call.has_release_set_hash = True
                    if has_value:
                        call.release_set_hash = value.copy()
                elif flag == String("--channel"):
                    call.has_channel = True
                k += 1
            out.append(call^)
    return out^


def _call_args(w: List[String], start: Int) -> List[String]:
    """The words of one invocation from `start`: up to the end of the line,
    a separator word, or a word ending in `;` (kept, without the `;`)."""
    var out = List[String]()
    var k = start
    while k < len(w):
        var word = w[k].copy()
        if word == String(";") or word == String("&&") or word == String("||") or word == String("|"):
            break
        var last = word.endswith(String(";"))
        while word.endswith(String(";")):
            var trimmed = String(word[byte = 0 : word.byte_length() - 1])
            word = trimmed^
        if word.byte_length() > 0:
            out.append(word^)
        if last:
            break
        k += 1
    return out^


