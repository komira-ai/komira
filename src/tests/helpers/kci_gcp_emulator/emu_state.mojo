# =============================================================================
# kci_gcp_emulator/emu_state.mojo: what the emulated cloud holds.
# =============================================================================
#
# One project, `GcpEmulator.project`, in one region, with:
#   * SERVICE ACCOUNTS (`EmuAccount`): an account id, an email
#     `<id>@<project>.iam.gserviceaccount.com`, a display name and a
#     description (at most 256 bytes, as IAM bounds it). An account marked
#     `outside` is an identity of another cell planted by the kit's step 14:
#     IAM lists it like any account, and it is never counted as a node of
#     this cell (`live_count`).
#   * an IAM POLICY per account and one for the project (`EmuPolicy`: role
#     bindings, each a role and its members, and an etag that changes on
#     every write; a write carrying a stale etag is refused ABORTED). The
#     project policy starts with one owner, a human user, as a real
#     project's does.
#   * Cloud Run JOBS (`EmuJob`): the job's JSON as the create carried it,
#     with the fields the service sets (name, uid, generation, etag, the
#     terminal condition); a job put in the failed state reports
#     `CONDITION_FAILED` until its next update.
#
# THE HOOKS the conformance kit drives (a conformance target turns its node
# words into these keys; a binding's key is `<resource>|<member>|<role>`):
#   * `race_next`: the next create (an account, a job, or a policy write
#     adding a member) first lands as if another writer of the same cell had
#     sent it a moment earlier, then is refused ALREADY_EXISTS (ABORTED for a
#     policy); `raced_key` names what it hit.
#   * `fail_after(key)`: the create of `key` stores the object as the
#     request carried it, then answers 504 DEADLINE_EXCEEDED, as a create
#     whose wait timed out; `failed_after_key` names it once hit.
#   * `planted` members: added to a policy out of band, never counted, never
#     a served call.
# COUNTERS: `mutations` (every served create, patch, delete and policy
# write), `creates[key]` (creates of one object over the emulator's life,
# the other writer's in a race included).
# =============================================================================

from komira_json import JsonValue


comptime IAM_HOST = "127.0.0.1"
"""The host the emulator answers IAM on (an IP literal: no DNS)."""
comptime CRM_HOST = "127.0.0.2"
"""The host it answers Cloud Resource Manager on."""
comptime RUN_HOST = "127.0.0.3"
"""The host it answers Cloud Run on."""
comptime TOKENINFO_HOST = "127.0.0.4"
"""The host it answers the token-information endpoint on."""
comptime EMU_TOKEN = "emulator-access-token"
"""The one access token the emulator accepts."""
comptime EMU_DEPLOYER = "deployer@demo-project.example"
"""The principal the emulator's token-information endpoint names."""
comptime OWNER_MEMBER = "user:owner@demo-project.example"
"""The human owner the project policy starts with."""
comptime ACCOUNT_DESCRIPTION_MAX = 256
"""IAM's bound on a service account's description, in bytes."""
comptime SA_DOMAIN = ".iam.gserviceaccount.com"


struct EmuAccount(Copyable, Movable):
    var account_id: String
    var email: String
    var display_name: String
    var description: String
    var unique_id: String
    var outside: Bool

    def __init__(
        out self,
        account_id: String,
        email: String,
        display_name: String,
        description: String,
        unique_id: String,
        outside: Bool = False,
    ):
        self.account_id = account_id
        self.email = email
        self.display_name = display_name
        self.description = description
        self.unique_id = unique_id
        self.outside = outside

    def __init__(out self, *, copy: Self):
        self.account_id = copy.account_id.copy()
        self.email = copy.email.copy()
        self.display_name = copy.display_name.copy()
        self.description = copy.description.copy()
        self.unique_id = copy.unique_id.copy()
        self.outside = copy.outside


struct EmuBinding(Copyable, Movable):
    var role: String
    var members: List[String]

    def __init__(out self, role: String, var members: List[String]):
        self.role = role
        self.members = members^

    def __init__(out self, *, copy: Self):
        self.role = copy.role.copy()
        self.members = copy.members.copy()


struct EmuPolicy(Copyable, Movable):
    """The policy of `resource` (`projects/<p>` or an account's name)."""

    var resource: String
    var bindings: List[EmuBinding]
    var version: Int

    def __init__(out self, resource: String):
        self.resource = resource
        self.bindings = List[EmuBinding]()
        self.version = 1

    def __init__(out self, *, copy: Self):
        self.resource = copy.resource.copy()
        self.bindings = copy.bindings.copy()
        self.version = copy.version

    def has(self, member: String, role: String) -> Bool:
        for i in range(len(self.bindings)):
            if self.bindings[i].role != role:
                continue
            for k in range(len(self.bindings[i].members)):
                if self.bindings[i].members[k] == member:
                    return True
        return False

    def add(mut self, member: String, role: String):
        for i in range(len(self.bindings)):
            if self.bindings[i].role == role:
                for k in range(len(self.bindings[i].members)):
                    if self.bindings[i].members[k] == member:
                        return
                self.bindings[i].members.append(member)
                return
        var m = List[String]()
        m.append(member)
        self.bindings.append(EmuBinding(role, m^))


struct EmuJob(Copyable, Movable):
    """A job: its name (`projects/<p>/locations/<r>/jobs/<id>`) and its
    JSON as the service holds it."""

    var name: String
    var body: JsonValue
    var failed: Bool

    def __init__(out self, name: String, var body: JsonValue):
        self.name = name
        self.body = body^
        self.failed = False

    def __init__(out self, *, copy: Self):
        self.name = copy.name.copy()
        self.body = copy.body.copy()
        self.failed = copy.failed


struct GcpEmulator(Movable):
    """The emulated cloud (the file header). The routes (emu_iam.mojo,
    emu_policy.mojo, emu_run.mojo, emu_serve.mojo) read and change it; a
    test plants into it out of band."""

    var project: String
    var region: String
    var accounts: List[EmuAccount]
    var policies: List[EmuPolicy]
    var jobs: List[EmuJob]
    var page_cap: Int
    var mutations: Int
    var create_keys: List[String]
    var create_counts: List[Int]
    var race_next: Bool
    var raced_key: String
    var fail_after_key: String
    var failed_after_key: String
    var planted_keys: List[String]
    var requests: Int
    var next_id: Int

    def __init__(out self, project: String = String("demo-project"), region: String = String("europe-west1")):
        self.project = project
        self.region = region
        self.accounts = List[EmuAccount]()
        self.policies = List[EmuPolicy]()
        var owner = EmuPolicy(String("projects/") + project)
        owner.add(String(OWNER_MEMBER), String("roles/owner"))
        self.policies.append(owner^)
        self.jobs = List[EmuJob]()
        self.page_cap = 2
        self.mutations = 0
        self.create_keys = List[String]()
        self.create_counts = List[Int]()
        self.race_next = False
        self.raced_key = String("")
        self.fail_after_key = String("")
        self.failed_after_key = String("")
        self.planted_keys = List[String]()
        self.requests = 0
        self.next_id = 1000

    # --- names --------------------------------------------------------------

    def email_of(self, account_id: String) -> String:
        return account_id + String("@") + self.project + String(SA_DOMAIN)

    def account_name(self, email: String) -> String:
        return String("projects/") + self.project + String("/serviceAccounts/") + email

    def project_resource(self) -> String:
        return String("projects/") + self.project

    def job_name(self, job_id: String) -> String:
        return String("projects/") + self.project + String("/locations/") + self.region + String("/jobs/") + job_id

    def fresh_id(mut self) -> String:
        self.next_id += 1
        return String(self.next_id)

    # --- lookups ------------------------------------------------------------

    def account_index(self, email: String) -> Int:
        for i in range(len(self.accounts)):
            if self.accounts[i].email == email:
                return i
        return -1

    def policy_index(self, resource: String) -> Int:
        for i in range(len(self.policies)):
            if self.policies[i].resource == resource:
                return i
        return -1

    def policy_of(mut self, resource: String) -> Int:
        """The index of `resource`'s policy, made empty when it has none."""
        var i = self.policy_index(resource)
        if i >= 0:
            return i
        self.policies.append(EmuPolicy(resource))
        return len(self.policies) - 1

    def job_index(self, name: String) -> Int:
        for i in range(len(self.jobs)):
            if self.jobs[i].name == name:
                return i
        return -1

    # --- counters and hooks -------------------------------------------------

    def count_create(mut self, key: String):
        for i in range(len(self.create_keys)):
            if self.create_keys[i] == key:
                self.create_counts[i] += 1
                return
        self.create_keys.append(key)
        self.create_counts.append(1)

    def creates_of(self, key: String) -> Int:
        for i in range(len(self.create_keys)):
            if self.create_keys[i] == key:
                return self.create_counts[i]
        return 0

    def take_race(mut self, key: String) -> Bool:
        """True (once) when this create is the one `race_next` armed."""
        if not self.race_next:
            return False
        self.race_next = False
        self.raced_key = key
        return True

    def take_fail_after(mut self, key: String) -> Bool:
        """True (once) when this create is the one `fail_after` armed."""
        if self.fail_after_key.byte_length() == 0 or self.fail_after_key != key:
            return False
        self.fail_after_key = String("")
        self.failed_after_key = key
        return True

    def binding_key(self, resource: String, member: String, role: String) -> String:
        return resource + String("|") + member + String("|") + role

    def is_planted(self, key: String) -> Bool:
        for i in range(len(self.planted_keys)):
            if self.planted_keys[i] == key:
                return True
        return False

    def live_count(self) -> Int:
        """The nodes of the cell the cloud holds: every account not
        `outside`, every job, and every member binding of an account of this
        project that was not planted out of band."""
        var n = len(self.jobs)
        for i in range(len(self.accounts)):
            if not self.accounts[i].outside:
                n += 1
        var suffix = String("@") + self.project + String(SA_DOMAIN)
        for p in range(len(self.policies)):
            ref pol = self.policies[p]
            for b in range(len(pol.bindings)):
                ref bind = pol.bindings[b]
                for m in range(len(bind.members)):
                    ref member = bind.members[m]
                    if not member.startswith("serviceAccount:") or not member.endswith(suffix):
                        continue
                    if self.is_planted(self.binding_key(pol.resource, member, bind.role)):
                        continue
                    n += 1
        return n
