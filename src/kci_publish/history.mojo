# =============================================================================
# src/kci_publish/history.mojo -- `HistoryReader`: the git reads a
#   never-backward publish asks while it decides (run.mojo), and two
#   readers that run no git.
# =============================================================================
#
# A never-backward publish whose channel is ahead of the release splits by
# history (run.mojo, THE SPLIT): the commit the channel's newest build names
# (`h<8 hex>`) is resolved to ONE commit (`commit_of`, `git rev-parse
# --verify`), then git is asked whether the release revision is on that
# commit's history (`is_ancestor`, `git merge-base --is-ancestor`). Either
# read RAISES when git cannot answer: a prefix that names no commit or more
# than one, a shallow clone, a git that fails. A raise is never an answer:
# run.mojo stops the run CANNOT_TELL (exit 5).
#
# The question is asked only after the channel was read, so it cannot be
# answered ahead of the run the way the revision's history is
# (`RevisionHistory`, plan.mojo); kci_cli passes a reader over git
# (library_verbs.mojo). `UnreadHistory` answers nothing (a caller that
# gives no reader: any split cannot tell). `ScriptedHistory` answers from a
# table and records each question (the welded tests).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================


trait HistoryReader:
    """The two git reads of the split (file header)."""

    def commit_of(mut self, prefix: String) raises -> String:
        """The ONE full commit id `prefix` (8 lowercase hex) names. Raises
        when it names none or more than one, or git cannot tell."""
        ...

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        """Whether `commit` is on `of`'s history. Raises when git cannot
        tell."""
        ...


struct UnreadHistory(HistoryReader, Movable):
    """A reader that answers nothing, saying why. Layout: one owned
    String."""

    var why: String

    def __init__(out self, var why: String = String("no history reader was given to this publish")):
        self.why = why^

    def commit_of(mut self, prefix: String) raises -> String:
        raise Error(self.why.copy())

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        raise Error(self.why.copy())


struct ScriptedHistory(HistoryReader, Movable):
    """Answers from tables: `commit_of(p)` is the commit `put_commit` gave
    `p`, or raises with the reason `refuse_prefix` gave it (or "unknown");
    `is_ancestor(c, of)` is True for each pair `put_ancestor` gave, False
    for any other, and raises for an `of` `refuse_ancestor` named. Every
    question is recorded in `asked`. Layout: owned lists only."""

    var prefixes: List[String]
    var commits: List[String]
    var refused_prefixes: List[String]
    var refused_why: List[String]
    var ancestors: List[String]
    var refused_of: List[String]
    var asked: List[String]

    def __init__(out self):
        self.prefixes = List[String]()
        self.commits = List[String]()
        self.refused_prefixes = List[String]()
        self.refused_why = List[String]()
        self.ancestors = List[String]()
        self.refused_of = List[String]()
        self.asked = List[String]()

    def put_commit(mut self, prefix: String, commit: String):
        self.prefixes.append(prefix.copy())
        self.commits.append(commit.copy())

    def refuse_prefix(mut self, prefix: String, why: String):
        self.refused_prefixes.append(prefix.copy())
        self.refused_why.append(why.copy())

    def put_ancestor(mut self, commit: String, of: String):
        self.ancestors.append(commit + String(" ") + of)

    def refuse_ancestor(mut self, of: String):
        self.refused_of.append(of.copy())

    def commit_of(mut self, prefix: String) raises -> String:
        self.asked.append(String("commit_of ") + prefix)
        for i in range(len(self.refused_prefixes)):
            if self.refused_prefixes[i] == prefix:
                raise Error(self.refused_why[i].copy())
        for i in range(len(self.prefixes)):
            if self.prefixes[i] == prefix:
                return self.commits[i].copy()
        raise Error(String("`") + prefix + String("` names no commit (unknown)"))

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        self.asked.append(String("is_ancestor ") + commit + String(" ") + of)
        for i in range(len(self.refused_of)):
            if self.refused_of[i] == of:
                raise Error(String("the checkout is shallow: its history cannot tell"))
        var want = commit + String(" ") + of
        for i in range(len(self.ancestors)):
            if self.ancestors[i] == want:
                return True
        return False
