//! The AWS protocol conformance harness: loads botocore's protocol test
//! corpus and compares what an implementation serializes and deserializes
//! against each case's expectations.

use crate::json::{parse as parse_json, Json, JsonObject};
use crate::xml_equiv::xml_bodies_equivalent;
use std::collections::{BTreeMap, BTreeSet};

// ---------------------------------------------------------------------------
// Corpus model
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Direction {
    Input,
    Output,
}

impl Direction {
    pub fn as_str(self) -> &'static str {
        match self {
            Direction::Input => "input",
            Direction::Output => "output",
        }
    }
}

/// What the corpus says a serialized request must look like.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ExpectedRequest {
    pub method: Option<String>,
    pub uri: Option<String>,
    pub host: Option<String>,
    pub body: Option<String>,
    pub headers: Vec<(String, String)>,
    pub require_headers: Vec<String>,
    pub forbid_headers: Vec<String>,
}

/// One input (serialization) case.
#[derive(Clone, Debug)]
pub struct InputCase {
    pub key: String,
    pub file: String,
    pub protocol: String,
    pub suite: String,
    pub id: String,
    pub description: String,
    /// The operation model fragment (`name`, `http`, `input`, ...).
    pub given: Json,
    /// The suite's shape dictionary — the model this case needs, and nothing
    /// else. This is what makes a case self-contained.
    pub shapes: Json,
    /// The operation input parameters.
    pub params: Json,
    pub client_endpoint: Option<String>,
    pub expected: ExpectedRequest,
}

/// The wire response an output case hands the deserializer.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct HttpResponse {
    pub status_code: i64,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

/// What the corpus says a deserialized response must contain.
#[derive(Clone, Debug, PartialEq)]
pub enum ExpectedResult {
    Success(Json),
    Error {
        code: Option<String>,
        message: Option<String>,
    },
}

/// One output (deserialization) case.
#[derive(Clone, Debug)]
pub struct OutputCase {
    pub key: String,
    pub file: String,
    pub protocol: String,
    pub suite: String,
    pub id: String,
    pub description: String,
    pub given: Json,
    pub shapes: Json,
    pub response: HttpResponse,
    pub expected: ExpectedResult,
}

/// The loaded corpus.
#[derive(Clone, Debug, Default)]
pub struct Corpus {
    pub input: Vec<InputCase>,
    pub output: Vec<OutputCase>,
}

// ---------------------------------------------------------------------------
// What an implementation under test produces
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ActualRequest {
    pub method: Option<String>,
    pub uri: Option<String>,
    pub host: Option<String>,
    pub body: Option<String>,
    pub headers: Vec<(String, String)>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ActualResponse {
    Success(Json),
    Error {
        code: Option<String>,
        message: Option<String>,
    },
}

pub trait InputSerializer {
    fn serialize(&mut self, case: &InputCase) -> Option<ActualRequest>;
}

/// In-process seam for a deserializer.
pub trait OutputDeserializer {
    fn deserialize(&mut self, case: &OutputCase) -> Option<ActualResponse>;
}

/// The out-of-process seam: actuals produced by any implementation, in any
/// language, read back by case key.
#[derive(Clone, Debug, Default)]
pub struct ActualsFile {
    pub input: BTreeMap<String, ActualRequest>,
    pub output: BTreeMap<String, ActualResponse>,
}

impl ActualsFile {
    pub fn parse(text: &str) -> Result<ActualsFile, String> {
        let root = parse_json(text)?;
        let obj = root
            .as_object()
            .ok_or_else(|| "actuals file must be a JSON object".to_string())?;
        let mut out = ActualsFile::default();
        if let Some(Json::Object(m)) = obj.get("input") {
            for (key, v) in m {
                let o = v
                    .as_object()
                    .ok_or_else(|| format!("actuals input `{key}` must be an object"))?;
                out.input.insert(
                    key.clone(),
                    ActualRequest {
                        method: str_field(o.get("method")),
                        uri: str_field(o.get("uri")),
                        host: str_field(o.get("host")),
                        body: str_field(o.get("body")),
                        headers: header_pairs(o.get("headers")),
                    },
                );
            }
        }
        if let Some(Json::Object(m)) = obj.get("output") {
            for (key, v) in m {
                let o = v
                    .as_object()
                    .ok_or_else(|| format!("actuals output `{key}` must be an object"))?;
                let resp = if o.contains_key("errorCode") || o.contains_key("errorMessage") {
                    ActualResponse::Error {
                        code: str_field(o.get("errorCode")),
                        message: str_field(o.get("errorMessage")),
                    }
                } else {
                    ActualResponse::Success(
                        o.get("result").cloned().unwrap_or(Json::Object(JsonObject::new())),
                    )
                };
                out.output.insert(key.clone(), resp);
            }
        }
        Ok(out)
    }
}

impl InputSerializer for ActualsFile {
    fn serialize(&mut self, case: &InputCase) -> Option<ActualRequest> {
        self.input.get(&case.key).cloned()
    }
}

impl OutputDeserializer for ActualsFile {
    fn deserialize(&mut self, case: &OutputCase) -> Option<ActualResponse> {
        self.output.get(&case.key).cloned()
    }
}

fn str_field(v: Option<&Json>) -> Option<String> {
    match v {
        Some(Json::Str(s)) => Some(s.clone()),
        _ => None,
    }
}

fn header_pairs(v: Option<&Json>) -> Vec<(String, String)> {
    match v {
        Some(Json::Object(m)) => m
            .iter()
            .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
            .collect(),
        _ => Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load one corpus file. `file` is the bare basename (`"rest-xml.json"`); it
/// becomes part of every case key, so it must match the vendored filename.
pub fn load_file(
    direction: Direction,
    file: &str,
    text: &str,
) -> Result<Corpus, String> {
    let root = parse_json(text).map_err(|e| format!("{file}: {e}"))?;
    let suites = root
        .as_array()
        .ok_or_else(|| format!("{file}: top level must be an array of suites"))?;
    let mut corpus = Corpus::default();
    for suite in suites {
        let s = suite
            .as_object()
            .ok_or_else(|| format!("{file}: a suite must be an object"))?;
        let protocol = s
            .get("metadata")
            .and_then(|m| m.get("protocol"))
            .and_then(|p| p.as_str())
            .ok_or_else(|| format!("{file}: a suite has no metadata.protocol"))?
            .to_string();
        let suite_desc = s
            .get("description")
            .and_then(|d| d.as_str())
            .unwrap_or("")
            .to_string();
        let shapes = s.get("shapes").cloned().unwrap_or(Json::Object(JsonObject::new()));
        let client_endpoint = s.get("clientEndpoint").and_then(|c| c.as_str()).map(String::from);
        let cases = s
            .get("cases")
            .and_then(|c| c.as_array())
            .ok_or_else(|| format!("{file}: suite `{suite_desc}` has no cases"))?;
        for case in cases {
            let c = case
                .as_object()
                .ok_or_else(|| format!("{file}: a case must be an object"))?;
            // Every corpus case carries an `id`; the key uniqueness test
            // depends on it, so a missing one is an error rather than a
            // silently-synthesised index.
            let id = c
                .get("id")
                .and_then(|i| i.as_str())
                .ok_or_else(|| format!("{file}: a case in `{suite_desc}` has no id"))?
                .to_string();
            let key = format!("{}/{}#{}", direction.as_str(), file, id);
            let description = c
                .get("description")
                .and_then(|d| d.as_str())
                .unwrap_or("")
                .to_string();
            let given = c.get("given").cloned().unwrap_or(Json::Null);
            match direction {
                Direction::Input => {
                    let ser = c
                        .get("serialized")
                        .and_then(|x| x.as_object())
                        .ok_or_else(|| format!("{key}: no `serialized`"))?;
                    corpus.input.push(InputCase {
                        key,
                        file: file.to_string(),
                        protocol: protocol.clone(),
                        suite: suite_desc.clone(),
                        id,
                        description,
                        given,
                        shapes: shapes.clone(),
                        params: c.get("params").cloned().unwrap_or(Json::Object(JsonObject::new())),
                        client_endpoint: client_endpoint.clone(),
                        expected: ExpectedRequest {
                            method: str_field(ser.get("method")),
                            uri: str_field(ser.get("uri")),
                            host: str_field(ser.get("host")),
                            body: str_field(ser.get("body")),
                            headers: header_pairs(ser.get("headers")),
                            require_headers: str_array(ser.get("requireHeaders")),
                            forbid_headers: str_array(ser.get("forbidHeaders")),
                        },
                    });
                }
                Direction::Output => {
                    let resp = c
                        .get("response")
                        .and_then(|x| x.as_object())
                        .ok_or_else(|| format!("{key}: no `response`"))?;
                    let expected = if c.contains_key("errorCode") || c.contains_key("error") {
                        ExpectedResult::Error {
                            code: str_field(c.get("errorCode")),
                            message: str_field(c.get("errorMessage")),
                        }
                    } else {
                        ExpectedResult::Success(
                            c.get("result").cloned().unwrap_or(Json::Object(JsonObject::new())),
                        )
                    };
                    corpus.output.push(OutputCase {
                        key,
                        file: file.to_string(),
                        protocol: protocol.clone(),
                        suite: suite_desc.clone(),
                        id,
                        description,
                        given,
                        shapes: shapes.clone(),
                        response: HttpResponse {
                            status_code: match resp.get("status_code") {
                                Some(Json::Number(n)) => *n as i64,
                                _ => 0,
                            },
                            headers: header_pairs(resp.get("headers")),
                            body: str_field(resp.get("body")).unwrap_or_default(),
                        },
                        expected,
                    });
                }
            }
        }
    }
    Ok(corpus)
}

fn str_array(v: Option<&Json>) -> Vec<String> {
    match v {
        Some(Json::Array(a)) => a.iter().filter_map(|x| x.as_str().map(String::from)).collect(),
        _ => Vec::new(),
    }
}

impl Corpus {
    pub fn extend(&mut self, other: Corpus) {
        self.input.extend(other.input);
        self.output.extend(other.output);
    }

    /// Every case key in the corpus, in load order.
    pub fn keys(&self) -> Vec<String> {
        let mut v: Vec<String> = self.input.iter().map(|c| c.key.clone()).collect();
        v.extend(self.output.iter().map(|c| c.key.clone()));
        v
    }
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

/// Which part of a serialisation disagreed. The mutation self-test asserts on
/// the FIELD, not on the message, so that "the comparator noticed" cannot be
/// confused with "the comparator noticed the right thing".
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Field {
    Method,
    Uri,
    Host,
    Body,
    Header(String),
    RequiredHeader(String),
    ForbiddenHeader(String),
    Result,
    ErrorCode,
    ErrorMessage,
    ErrorVsSuccess,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Mismatch {
    pub field: Field,
    pub expected: String,
    pub actual: String,
}

fn cmp_opt(field: Field, expected: &Option<String>, actual: &Option<String>, out: &mut Vec<Mismatch>) {
    if let Some(e) = expected {
        let a = actual.clone().unwrap_or_default();
        if &a != e {
            out.push(Mismatch {
                field,
                expected: e.clone(),
                actual: a,
            });
        }
    }
}

/// Compare a produced request against what the case expects.
/// An empty result means the case PASSES.
pub fn compare_request(case: &InputCase, actual: &ActualRequest) -> Vec<Mismatch> {
    let mut out = Vec::new();
    cmp_opt(Field::Method, &case.expected.method, &actual.method, &mut out);
    cmp_opt(Field::Uri, &case.expected.uri, &actual.uri, &mut out);
    cmp_opt(Field::Host, &case.expected.host, &actual.host, &mut out);

    if let Some(expected_body) = &case.expected.body {
        let actual_body = actual.body.clone().unwrap_or_default();
        if !bodies_equivalent(&case.protocol, &actual_body, expected_body) {
            out.push(Mismatch {
                field: Field::Body,
                expected: expected_body.clone(),
                actual: actual_body,
            });
        }
    }

    let actual_headers: BTreeMap<String, String> = actual
        .headers
        .iter()
        .map(|(k, v)| (k.to_ascii_lowercase(), v.clone()))
        .collect();
    for (name, value) in &case.expected.headers {
        let got = actual_headers.get(&name.to_ascii_lowercase());
        if got.map(String::as_str) != Some(value.as_str()) {
            out.push(Mismatch {
                field: Field::Header(name.clone()),
                expected: value.clone(),
                actual: got.cloned().unwrap_or_else(|| "<absent>".into()),
            });
        }
    }
    for name in &case.expected.require_headers {
        if !actual_headers.contains_key(&name.to_ascii_lowercase()) {
            out.push(Mismatch {
                field: Field::RequiredHeader(name.clone()),
                expected: "<present>".into(),
                actual: "<absent>".into(),
            });
        }
    }
    for name in &case.expected.forbid_headers {
        if let Some(v) = actual_headers.get(&name.to_ascii_lowercase()) {
            out.push(Mismatch {
                field: Field::ForbiddenHeader(name.clone()),
                expected: "<absent>".into(),
                actual: v.clone(),
            });
        }
    }
    out
}

/// Compare a deserialized response against what the case expects.
pub fn compare_response(case: &OutputCase, actual: &ActualResponse) -> Vec<Mismatch> {
    let mut out = Vec::new();
    match (&case.expected, actual) {
        (ExpectedResult::Success(e), ActualResponse::Success(a)) => {
            if e != a {
                out.push(Mismatch {
                    field: Field::Result,
                    expected: format!("{e:?}"),
                    actual: format!("{a:?}"),
                });
            }
        }
        (
            ExpectedResult::Error { code, message },
            ActualResponse::Error {
                code: acode,
                message: amessage,
            },
        ) => {
            cmp_opt(Field::ErrorCode, code, acode, &mut out);
            cmp_opt(Field::ErrorMessage, message, amessage, &mut out);
        }
        (e, a) => out.push(Mismatch {
            field: Field::ErrorVsSuccess,
            expected: format!("{e:?}"),
            actual: format!("{a:?}"),
        }),
    }
    out
}

/// Body equivalence, per protocol. See the module doc's table.
pub fn bodies_equivalent(protocol: &str, actual: &str, expected: &str) -> bool {
    match protocol {
        "rest-xml" => xml_bodies_equivalent(actual, expected),
        "json" | "rest-json" => match (parse_json(actual), parse_json(expected)) {
            (Ok(a), Ok(e)) => a == e,
            _ => actual == expected,
        },
        _ => actual == expected,
    }
}

// ---------------------------------------------------------------------------
// Running + the report
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub total: usize,
    pub passing: usize,
    pub failing: usize,
}

impl Counts {
    pub fn unsupported(&self) -> usize {
        self.total - self.passing - self.failing
    }
}

/// One row per (protocol, direction), plus the per-case detail a human needs
/// to act on a red run.
#[derive(Clone, Debug, Default)]
pub struct Report {
    pub rows: BTreeMap<(String, Direction), Counts>,
    /// Case key -> the mismatches that made it fail. Passing and unsupported
    /// cases are absent.
    pub failures: BTreeMap<String, Vec<Mismatch>>,
    pub passing_keys: BTreeSet<String>,
}

impl Report {
    pub fn totals(&self) -> Counts {
        let mut t = Counts::default();
        for c in self.rows.values() {
            t.total += c.total;
            t.passing += c.passing;
            t.failing += c.failing;
        }
        t
    }

    pub fn to_ledger(&self) -> String {
        let mut s = String::new();
        for ((protocol, direction), c) in &self.rows {
            s.push_str(&format!(
                "{:<28} {:<7} {:>5} {:>5} {:>5}\n",
                protocol,
                direction.as_str(),
                c.total,
                c.passing,
                c.failing
            ));
        }
        s
    }
}

/// Run the corpus against an implementation of the in-process seam.
pub fn run(
    corpus: &Corpus,
    input: &mut dyn InputSerializer,
    output: &mut dyn OutputDeserializer,
) -> Report {
    let mut report = Report::default();
    for case in &corpus.input {
        let row = report
            .rows
            .entry((case.protocol.clone(), Direction::Input))
            .or_default();
        row.total += 1;
        match input.serialize(case) {
            None => {}
            Some(actual) => {
                let mismatches = compare_request(case, &actual);
                if mismatches.is_empty() {
                    row.passing += 1;
                    report.passing_keys.insert(case.key.clone());
                } else {
                    row.failing += 1;
                    report.failures.insert(case.key.clone(), mismatches);
                }
            }
        }
    }
    for case in &corpus.output {
        let row = report
            .rows
            .entry((case.protocol.clone(), Direction::Output))
            .or_default();
        row.total += 1;
        match output.deserialize(case) {
            None => {}
            Some(actual) => {
                let mismatches = compare_response(case, &actual);
                if mismatches.is_empty() {
                    row.passing += 1;
                    report.passing_keys.insert(case.key.clone());
                } else {
                    row.failing += 1;
                    report.failures.insert(case.key.clone(), mismatches);
                }
            }
        }
    }
    report
}


#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LedgerViolation {
    /// The vendored corpus changed size under a row.
    CorpusDrift {
        row: String,
        ledger_total: usize,
        actual_total: usize,
    },
    Regression {
        row: String,
        ledger_passing: usize,
        actual_passing: usize,
    },
    Stale {
        row: String,
        ledger_passing: usize,
        actual_passing: usize,
    },
    /// More produced-but-wrong cases than recorded.
    FailingGrew {
        row: String,
        ledger_failing: usize,
        actual_failing: usize,
    },
    FailingStale {
        row: String,
        ledger_failing: usize,
        actual_failing: usize,
    },
    /// A row admitting failures with no `# reason:` line above it.
    FailingWithoutReason { row: String },
    MissingRow { row: String },
    ExtraRow { row: String },
    Malformed { line_no: usize, line: String },
}

struct LedgerRow {
    total: usize,
    passing: usize,
    failing: usize,
    has_reason: bool,
}

fn parse_ledger(text: &str) -> Result<BTreeMap<String, LedgerRow>, LedgerViolation> {
    let mut rows = BTreeMap::new();
    let mut reason_pending = false;
    for (idx, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() {
            reason_pending = false;
            continue;
        }
        if let Some(rest) = line.strip_prefix('#') {
            if rest.trim_start().to_ascii_lowercase().starts_with("reason:") {
                reason_pending = true;
            }
            continue;
        }
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() != 5 {
            return Err(LedgerViolation::Malformed {
                line_no: idx + 1,
                line: raw.to_string(),
            });
        }
        let nums: Result<Vec<usize>, _> = f[2..].iter().map(|s| s.parse::<usize>()).collect();
        let nums = nums.map_err(|_| LedgerViolation::Malformed {
            line_no: idx + 1,
            line: raw.to_string(),
        })?;
        rows.insert(
            format!("{} {}", f[0], f[1]),
            LedgerRow {
                total: nums[0],
                passing: nums[1],
                failing: nums[2],
                has_reason: reason_pending,
            },
        );
        reason_pending = false;
    }
    Ok(rows)
}

pub fn check_ledger(report: &Report, ledger_text: &str) -> Vec<LedgerViolation> {
    let rows = match parse_ledger(ledger_text) {
        Ok(r) => r,
        Err(v) => return vec![v],
    };
    let mut violations = Vec::new();
    let mut seen = BTreeSet::new();
    for ((protocol, direction), c) in &report.rows {
        let name = format!("{} {}", protocol, direction.as_str());
        seen.insert(name.clone());
        let Some(row) = rows.get(&name) else {
            violations.push(LedgerViolation::MissingRow { row: name });
            continue;
        };
        if row.total != c.total {
            violations.push(LedgerViolation::CorpusDrift {
                row: name.clone(),
                ledger_total: row.total,
                actual_total: c.total,
            });
        }
        if c.passing < row.passing {
            violations.push(LedgerViolation::Regression {
                row: name.clone(),
                ledger_passing: row.passing,
                actual_passing: c.passing,
            });
        } else if c.passing > row.passing {
            violations.push(LedgerViolation::Stale {
                row: name.clone(),
                ledger_passing: row.passing,
                actual_passing: c.passing,
            });
        }
        if c.failing > row.failing {
            violations.push(LedgerViolation::FailingGrew {
                row: name.clone(),
                ledger_failing: row.failing,
                actual_failing: c.failing,
            });
        } else if c.failing < row.failing {
            violations.push(LedgerViolation::FailingStale {
                row: name.clone(),
                ledger_failing: row.failing,
                actual_failing: c.failing,
            });
        }
        if row.failing > 0 && !row.has_reason {
            violations.push(LedgerViolation::FailingWithoutReason { row: name.clone() });
        }
    }
    for name in rows.keys() {
        if !seen.contains(name) {
            violations.push(LedgerViolation::ExtraRow { row: name.clone() });
        }
    }
    violations
}
