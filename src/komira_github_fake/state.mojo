# =============================================================================
# komira_github_fake/state.mojo -- what the fake GitHub knows, and the
#   set-up verbs a test (or GitHub's own web flows) changes it with.
# =============================================================================
#
# INSTALLING. GitHub has no REST call that installs an App: a person does it
# in the web UI, and GitHub lets them pick only repositories they administer
# (an organization owner administers every repository of the organization).
# `install(account, installed_by, repo_ids, permissions)` is that flow and
# enforces the same rule: every repository must belong to `account` and
# `installed_by` must be an administrator of each one, or nothing is
# installed. The permissions must be ones the App asks for (`app_permissions`,
# set when the fake is made); the installation grants exactly those.
# =============================================================================

from komira_github import is_name_segment

from .model import (
    FakeArtifact,
    FakeCheckRun,
    FakeFile,
    FakeInstallation,
    FakeJob,
    FakeRepo,
    FakeRun,
    FakeToken,
    grants,
)


struct FakeState(Movable, Deinitable):
    """Every object of the fake (model.mojo) and its clock."""

    var now: Int64
    var app_permissions: List[String]
    var repos: List[FakeRepo]
    var installations: List[FakeInstallation]
    var tokens: List[FakeToken]
    var runs: List[FakeRun]
    var jobs: List[FakeJob]
    var artifacts: List[FakeArtifact]
    var check_runs: List[FakeCheckRun]
    var next_id: Int64
    var tokens_minted: Int

    def __init__(out self, now: Int64, var app_permissions: List[String]):
        self.now = now
        self.app_permissions = app_permissions^
        self.repos = List[FakeRepo]()
        self.installations = List[FakeInstallation]()
        self.tokens = List[FakeToken]()
        self.runs = List[FakeRun]()
        self.jobs = List[FakeJob]()
        self.artifacts = List[FakeArtifact]()
        self.check_runs = List[FakeCheckRun]()
        self.next_id = 1000
        self.tokens_minted = 0

    def new_id(mut self) -> Int64:
        self.next_id += 1
        return self.next_id

    # --- lookups --------------------------------------------------------------

    def repo_index(self, repo_id: Int64) -> Int:
        for i in range(len(self.repos)):
            if self.repos[i].id == repo_id:
                return i
        return -1

    def repo_index_by_name(self, owner: String, name: String) -> Int:
        for i in range(len(self.repos)):
            if self.repos[i].owner == owner and self.repos[i].name == name:
                return i
        return -1

    def installation_index(self, installation_id: Int64) -> Int:
        for i in range(len(self.installations)):
            if self.installations[i].id == installation_id:
                return i
        return -1

    def token_index(self, token: String) -> Int:
        for i in range(len(self.tokens)):
            if self.tokens[i].token == token:
                return i
        return -1

    def run_index(self, repo_id: Int64, run_id: Int64) -> Int:
        for i in range(len(self.runs)):
            if self.runs[i].id == run_id and self.runs[i].repo_id == repo_id:
                return i
        return -1

    # --- set-up verbs ---------------------------------------------------------

    def add_repo(mut self, owner: String, name: String, var admins: List[String]) raises -> Int64:
        """A repository of `owner` administered by `admins`; its id."""
        if not is_name_segment(owner) or not is_name_segment(name):
            raise Error("FakeGitHub: a repository needs a valid owner and name")
        if self.repo_index_by_name(owner, name) >= 0:
            raise Error("FakeGitHub: the repository already exists")
        var id = self.new_id()
        self.repos.append(
            FakeRepo(
                id, owner, name, admins^, List[String](), List[String](), List[FakeFile]()
            )
        )
        return id

    def set_collaborator(mut self, repo_id: Int64, login: String, permission: String) raises:
        """`login` gets `permission` (read, triage, write, maintain) on the
        repository. Administrators are set by `add_repo`."""
        var r = self.repo_index(repo_id)
        if r < 0:
            raise Error("FakeGitHub: no such repository")
        self.repos[r].collaborators.append(login)
        self.repos[r].collaborator_permissions.append(permission)

    def put_file(mut self, repo_id: Int64, git_ref: String, path: String, var content: List[UInt8]) raises:
        var r = self.repo_index(repo_id)
        if r < 0:
            raise Error("FakeGitHub: no such repository")
        self.repos[r].files.append(FakeFile(git_ref, path, content^))

    def install(
        mut self,
        account: String,
        installed_by: String,
        var repo_ids: List[Int64],
        var permissions: List[String],
    ) raises -> Int64:
        """Install the App on `repo_ids` of `account`, as `installed_by`
        (module header). Raises, installing nothing, when a repository is
        not `account`'s or `installed_by` does not administer it, or a
        permission is not one the App asks for."""
        if len(repo_ids) == 0:
            raise Error("FakeGitHub: an installation needs at least one repository")
        for i in range(len(repo_ids)):
            var r = self.repo_index(repo_ids[i])
            if r < 0:
                raise Error("FakeGitHub: no such repository")
            if self.repos[r].owner != account:
                raise Error("FakeGitHub: a repository does not belong to the installing account")
            if not self.repos[r].is_admin(installed_by):
                raise Error(
                    "FakeGitHub: "
                    + installed_by
                    + " does not administer "
                    + self.repos[r].full_name()
                    + "; only an administrator can install an App on it"
                )
        for i in range(len(permissions)):
            if not grants(self.app_permissions, permissions[i]):
                raise Error("FakeGitHub: the App does not ask for " + permissions[i])
        var id = self.new_id()
        self.installations.append(
            FakeInstallation(id, account, installed_by, repo_ids^, permissions^, False)
        )
        return id

    def suspend(mut self, installation_id: Int64) raises:
        var i = self.installation_index(installation_id)
        if i < 0:
            raise Error("FakeGitHub: no such installation")
        self.installations[i].suspended = True

    def add_run(
        mut self, repo_id: Int64, head_sha: String, status: String, conclusion: String, run_attempt: Int64 = 1
    ) raises -> Int64:
        if self.repo_index(repo_id) < 0:
            raise Error("FakeGitHub: no such repository")
        var id = self.new_id()
        self.runs.append(FakeRun(id, repo_id, head_sha, status, conclusion, run_attempt))
        return id

    def add_job(
        mut self,
        repo_id: Int64,
        run_id: Int64,
        run_attempt: Int64,
        name: String,
        status: String,
        conclusion: String,
    ) raises -> Int64:
        if self.run_index(repo_id, run_id) < 0:
            raise Error("FakeGitHub: no such run")
        var id = self.new_id()
        self.jobs.append(FakeJob(id, repo_id, run_id, run_attempt, name, status, conclusion))
        return id

    def add_artifact(mut self, repo_id: Int64, run_id: Int64, name: String, size: Int64) raises -> Int64:
        if self.run_index(repo_id, run_id) < 0:
            raise Error("FakeGitHub: no such run")
        var id = self.new_id()
        self.artifacts.append(FakeArtifact(id, repo_id, run_id, name, size))
        return id
