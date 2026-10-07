# =============================================================================
# fake_store.mojo -- the state of the fake AWS Secrets Manager
# =============================================================================
#
# Secrets and their versions, kept as the service keeps them:
#
#   * a version's id is the ClientRequestToken of the write that made it;
#   * staging labels move between versions: a new version that takes
#     AWSCURRENT hands the old current version AWSPREVIOUS, and the version
#     that held AWSPREVIOUS loses it (it keeps its value and no label);
#   * a secret deleted with a recovery window is scheduled for deletion: it
#     is still there (DescribeSecret shows its DeletedDate), its value cannot
#     be read or written, and its name stays taken until RestoreSecret, while
#     a forced delete removes it at once.
#
# Only SecretString values are kept (no SecretBinary). Times come from a
# counter starting at a fixed instant, so every answer is deterministic.
# =============================================================================

comptime STAGE_CURRENT = "AWSCURRENT"
comptime STAGE_PREVIOUS = "AWSPREVIOUS"
# 2026-10-01T00:00:00Z, the fake's first instant.
comptime FAKE_EPOCH_SECONDS: Float64 = 1790812800.0
comptime SECONDS_PER_DAY: Float64 = 86400.0


struct SecretVersion(Copyable, Movable):
    var version_id: String
    var value: String
    var stages: List[String]
    var created: Float64

    def __init__(
        out self, var version_id: String, var value: String, created: Float64
    ):
        self.version_id = version_id^
        self.value = value^
        self.stages = List[String]()
        self.created = created

    def has_stage(self, stage: String) -> Bool:
        for i in range(len(self.stages)):
            if self.stages[i] == stage:
                return True
        return False

    def drop_stage(mut self, stage: String):
        var kept = List[String]()
        for i in range(len(self.stages)):
            if self.stages[i] != stage:
                kept.append(self.stages[i].copy())
        self.stages = kept^


struct FakeSecret(Copyable, Movable):
    var name: String
    var arn: String
    var description: String
    var created: Float64
    var last_changed: Float64
    # The deletion date while the secret is scheduled for deletion.
    var deletion_date: Optional[Float64]
    var versions: List[SecretVersion]
    # The ClientRequestToken of the CreateSecret that made the secret, so a
    # replay of a create that carried no value is recognised (it made no
    # version whose id would hold the token).
    var create_token: String

    def __init__(
        out self, var name: String, var arn: String, created: Float64, var create_token: String
    ):
        self.name = name^
        self.arn = arn^
        self.create_token = create_token^
        self.description = String("")
        self.created = created
        self.last_changed = created
        self.deletion_date = Optional[Float64]()
        self.versions = List[SecretVersion]()

    def is_scheduled_for_deletion(self) -> Bool:
        return Bool(self.deletion_date)

    def version_index(self, version_id: String) -> Int:
        for i in range(len(self.versions)):
            if self.versions[i].version_id == version_id:
                return i
        return -1

    def staged_index(self, stage: String) -> Int:
        for i in range(len(self.versions)):
            if self.versions[i].has_stage(stage):
                return i
        return -1

    def add_version(
        mut self, var version: SecretVersion, stages: List[String]
    ):
        """Add `version` holding `stages`, moving each label off the version
        that held it; a version losing AWSCURRENT is given AWSPREVIOUS."""
        for s in range(len(stages)):
            ref stage = stages[s]
            var holder = self.staged_index(stage)
            if holder >= 0:
                self.versions[holder].drop_stage(stage)
                if stage == STAGE_CURRENT:
                    var prev = self.staged_index(String(STAGE_PREVIOUS))
                    if prev >= 0:
                        self.versions[prev].drop_stage(String(STAGE_PREVIOUS))
                    self.versions[holder].stages.append(String(STAGE_PREVIOUS))
            version.stages.append(stage.copy())
        self.last_changed = version.created
        self.versions.append(version^)


struct SecretStore(Movable):
    """Every secret the fake holds, in creation order, and its clock."""

    var region: String
    var account: String
    var secrets: List[FakeSecret]
    var ticks: Int
    # ARNs made so far; only ever grows, so no two secrets share an ARN,
    # a forced delete included.
    var arns_made: Int

    def __init__(out self, var region: String, var account: String):
        self.region = region^
        self.account = account^
        self.secrets = List[FakeSecret]()
        self.ticks = 0
        self.arns_made = 0

    def now(mut self) -> Float64:
        """The next instant: one second after the last one."""
        self.ticks += 1
        return FAKE_EPOCH_SECONDS + Float64(self.ticks)

    def find(self, secret_id: String) -> Int:
        """The index of the secret named, or whose ARN is, `secret_id`; -1
        when there is none."""
        for i in range(len(self.secrets)):
            if self.secrets[i].name == secret_id or self.secrets[i].arn == secret_id:
                return i
        return -1

    def new_arn(mut self, name: String) -> String:
        """An ARN in the service's form: the name, a hyphen and a
        six-character suffix. The suffix is the six digits of
        100000 + `arns_made` (then incremented), so it is never reused while
        fewer than 900000 secrets have been made."""
        var n = String(100000 + self.arns_made)
        self.arns_made += 1
        return (
            String("arn:aws:secretsmanager:")
            + self.region
            + ":"
            + self.account
            + ":secret:"
            + name
            + "-"
            + n
        )

    def remove(mut self, index: Int):
        var kept = List[FakeSecret]()
        for i in range(len(self.secrets)):
            if i != index:
                kept.append(self.secrets[i].copy())
        self.secrets = kept^
