# =============================================================================
# komira_github_fake/model.mojo -- the objects the fake GitHub holds.
# =============================================================================
#
# Plain records: repositories (with their administrators, collaborators and
# files), installations (account, repositories, permissions, suspension),
# the tokens the fake has minted, workflow runs, jobs, artifacts and check
# runs. Ids come from one counter in `FakeGitHub`, so no two objects of any
# kind share one. Permissions are `<name>:<read|write>` strings, as in
# komira_github's route table; `write` grants `read`.
# =============================================================================


def permission_name(p: String) -> String:
    var c = p.find(":")
    if c < 0:
        return p
    return String(p[byte=0:c])


def permission_level(p: String) -> String:
    var c = p.find(":")
    if c < 0:
        return String("")
    return String(p[byte = c + 1 : p.byte_length()])


def grants(held: List[String], need: String) -> Bool:
    """Whether the permissions `held` grant `need` (`write` grants
    `read`)."""
    var name = permission_name(need)
    var level = permission_level(need)
    for i in range(len(held)):
        if permission_name(held[i]) != name:
            continue
        var have = permission_level(held[i])
        if have == level or (have == "write" and level == "read"):
            return True
    return False


@fieldwise_init
struct FakeFile(Copyable, Movable, Deinitable):
    var git_ref: String
    var path: String
    var content: List[UInt8]


@fieldwise_init
struct FakeRepo(Copyable, Movable, Deinitable):
    var id: Int64
    var owner: String
    var name: String
    var admins: List[String]
    var collaborators: List[String]
    var collaborator_permissions: List[String]
    var files: List[FakeFile]

    def full_name(self) -> String:
        return self.owner + String("/") + self.name

    def is_admin(self, login: String) -> Bool:
        for i in range(len(self.admins)):
            if self.admins[i] == login:
                return True
        return False

    def permission_of(self, login: String) -> String:
        """`admin`, `write`, `read` or `none`."""
        if self.is_admin(login):
            return String("admin")
        for i in range(len(self.collaborators)):
            if self.collaborators[i] == login:
                return self.collaborator_permissions[i]
        return String("none")


@fieldwise_init
struct FakeInstallation(Copyable, Movable, Deinitable):
    var id: Int64
    var account: String
    var installed_by: String
    var repo_ids: List[Int64]
    var permissions: List[String]
    var suspended: Bool

    def has_repo(self, repo_id: Int64) -> Bool:
        for i in range(len(self.repo_ids)):
            if self.repo_ids[i] == repo_id:
                return True
        return False


@fieldwise_init
struct FakeToken(Copyable, Movable, Deinitable):
    """A minted installation token: its repositories (a subset of the
    installation's, never empty) and permissions."""

    var token: String
    var installation_id: Int64
    var repo_ids: List[Int64]
    var permissions: List[String]
    var expires_at: Int64

    def has_repo(self, repo_id: Int64) -> Bool:
        for i in range(len(self.repo_ids)):
            if self.repo_ids[i] == repo_id:
                return True
        return False


@fieldwise_init
struct FakeRun(Copyable, Movable, Deinitable):
    var id: Int64
    var repo_id: Int64
    var head_sha: String
    var status: String
    var conclusion: String
    var run_attempt: Int64


@fieldwise_init
struct FakeJob(Copyable, Movable, Deinitable):
    var id: Int64
    var repo_id: Int64
    var run_id: Int64
    var run_attempt: Int64
    var name: String
    var status: String
    var conclusion: String


@fieldwise_init
struct FakeArtifact(Copyable, Movable, Deinitable):
    var id: Int64
    var repo_id: Int64
    var run_id: Int64
    var name: String
    var size_in_bytes: Int64


@fieldwise_init
struct FakeCheckRun(Copyable, Movable, Deinitable):
    var id: Int64
    var repo_id: Int64
    var name: String
    var head_sha: String
    var status: String
    var conclusion: String
    var details_url: String
    var external_id: String
    var output_title: String
    var output_summary: String
