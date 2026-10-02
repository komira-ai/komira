//! The AWS protocol conformance harness: loads botocore's protocol test
//! corpus and compares what an implementation serializes and deserializes
//! against each case's expectations.
//!
//! Every case of a driven protocol comes to one [`Outcome`]: PASS,
//! UPSTREAM-SKIP (botocore's own ignore list), REFUSED (a named generator
//! refusal) or red. [`check_ledger`] holds the counts to the ledger in both
//! directions.

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

/// The out-of-process seam: actuals produced by any implementation, in any
/// language, read back by case key.
#[derive(Clone, Debug, Default)]
pub struct ActualsFile {
    pub input: BTreeMap<String, ActualRequest>,
    pub output: BTreeMap<String, ActualResponse>,
    /// Case key -> the generator error that stopped it (a suite that did
    /// not lower, a case the driver could not construct).
    pub refused: BTreeMap<String, String>,
    /// The protocols (suite `metadata.protocol`) the driver was generated
    /// for: the `--protocol` flags of aws-conformance-gen.
    pub protocols: BTreeSet<String>,
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
        if let Some(Json::Array(a)) = obj.get("protocols") {
            for p in a {
                let p = p
                    .as_str()
                    .ok_or_else(|| "actuals `protocols` must hold strings".to_string())?;
                out.protocols.insert(p.to_string());
            }
        }
        if let Some(Json::Object(m)) = obj.get("refused") {
            for (key, v) in m {
                let text = v
                    .as_str()
                    .ok_or_else(|| format!("actuals refused `{key}` must be a string"))?;
                out.refused.insert(key.clone(), text.to_string());
            }
        }
        Ok(out)
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
        // botocore does not compare a rest-xml Content-Type
        // (test_protocols.py, `_assert_expected_headers_in_request`).
        if case.protocol == "rest-xml" && name.eq_ignore_ascii_case("content-type") {
            continue;
        }
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
// botocore's ignore list
// ---------------------------------------------------------------------------

/// botocore's `protocol-tests-ignore-list.json`, read as botocore reads it
/// (`tests/unit/test_protocols.py`, `_should_ignore_test`): a `general`
/// section for every protocol, and a `protocols` section keyed by the corpus
/// file's BASENAME without `.json` (`json_1_0`, not the suite's
/// `metadata.protocol`). Each section holds, per direction, `suites`
/// (matched against a suite's `description`) and `cases` (matched against a
/// case's `id`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct IgnoreList {
    general: BTreeMap<String, IgnoreSection>,
    protocols: BTreeMap<String, BTreeMap<String, IgnoreSection>>,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct IgnoreSection {
    suites: BTreeSet<String>,
    cases: BTreeSet<String>,
}

fn ignore_section(v: &Json, at: &str) -> Result<IgnoreSection, String> {
    let o = v
        .as_object()
        .ok_or_else(|| format!("ignore list: `{at}` is not an object"))?;
    let mut s = IgnoreSection::default();
    for (k, list) in o.iter() {
        let target = match k.as_str() {
            "suites" => &mut s.suites,
            "cases" => &mut s.cases,
            other => return Err(format!("ignore list: `{at}` has an unknown key `{other}`")),
        };
        let a = list
            .as_array()
            .ok_or_else(|| format!("ignore list: `{at}.{k}` is not an array"))?;
        for x in a {
            let name = x
                .as_str()
                .ok_or_else(|| format!("ignore list: `{at}.{k}` holds a non-string"))?;
            target.insert(name.to_string());
        }
    }
    Ok(s)
}

fn direction_sections(v: &Json, at: &str) -> Result<BTreeMap<String, IgnoreSection>, String> {
    let o = v
        .as_object()
        .ok_or_else(|| format!("ignore list: `{at}` is not an object"))?;
    let mut out = BTreeMap::new();
    for (dir, sec) in o.iter() {
        if dir != "input" && dir != "output" {
            return Err(format!("ignore list: `{at}` has an unknown direction `{dir}`"));
        }
        out.insert(dir.clone(), ignore_section(sec, &format!("{at}.{dir}"))?);
    }
    Ok(out)
}

impl IgnoreList {
    /// Parse the file. An unknown key anywhere is refused: a section this
    /// reader would not apply is a skip botocore applies and we would not.
    pub fn parse(text: &str) -> Result<IgnoreList, String> {
        let root = parse_json(text).map_err(|e| format!("ignore list: {e}"))?;
        let o = root
            .as_object()
            .ok_or_else(|| "ignore list: top level is not an object".to_string())?;
        let mut out = IgnoreList::default();
        for (k, v) in o.iter() {
            match k.as_str() {
                "general" => out.general = direction_sections(v, "general")?,
                "protocols" => {
                    let p = v
                        .as_object()
                        .ok_or_else(|| "ignore list: `protocols` is not an object".to_string())?;
                    for (name, sec) in p.iter() {
                        out.protocols
                            .insert(name.clone(), direction_sections(sec, &format!("protocols.{name}"))?);
                    }
                }
                other => return Err(format!("ignore list: unknown top-level key `{other}`")),
            }
        }
        Ok(out)
    }

    /// Whether botocore skips the case. `file` is the corpus basename
    /// (`json_1_0.json`); its stem is the protocol key, as in botocore.
    pub fn skips(&self, direction: Direction, file: &str, suite: &str, id: &str) -> bool {
        let dir = direction.as_str();
        let hit = |s: Option<&IgnoreSection>| {
            s.map(|s| s.suites.contains(suite) || s.cases.contains(id))
                .unwrap_or(false)
        };
        if hit(self.general.get(dir)) {
            return true;
        }
        let stem = file.strip_suffix(".json").unwrap_or(file);
        hit(self.protocols.get(stem).and_then(|p| p.get(dir)))
    }
}

// ---------------------------------------------------------------------------
// Refusals
// ---------------------------------------------------------------------------

/// The marker a NAMED generator refusal carries: `REFUSED <name>: <why>`,
/// anywhere in the error text (a caller may wrap it). `<name>` is lower
/// case letters, digits and `-`. A generation error without it is not a
/// refusal; the harness scores it red.
pub const REFUSAL_MARKER: &str = "REFUSED ";

/// The refusal name in a generator error, or `None` for an unnamed error.
pub fn refusal_name(text: &str) -> Option<String> {
    let mut rest = text;
    while let Some(at) = rest.find(REFUSAL_MARKER) {
        let after = &rest[at + REFUSAL_MARKER.len()..];
        let name: String = after
            .chars()
            .take_while(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '-')
            .collect();
        if !name.is_empty()
            && name.starts_with(|c: char| c.is_ascii_lowercase())
            && after[name.len()..].starts_with(':')
        {
            return Some(name);
        }
        rest = after;
    }
    None
}

// ---------------------------------------------------------------------------
// Running + the report
// ---------------------------------------------------------------------------

/// What one case came to. Every case of an enabled protocol is exactly one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The implementation produced exactly what the case expects.
    Pass,
    /// botocore's pinned ignore list skips it.
    UpstreamSkip,
    /// The generator refused a named model feature the case uses.
    Refused(String),
    /// Anything else: a wrong answer, no answer, an unnamed generation
    /// error, or an answer for a case botocore skips. Always red.
    Failed(String),
}

/// One (protocol, direction) row.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RowCounts {
    pub total: usize,
    pub pass: usize,
    pub upstream_skip: usize,
    /// Refusal name -> cases.
    pub refused: BTreeMap<String, usize>,
    pub failed: usize,
}

#[derive(Clone, Debug, Default)]
pub struct Report {
    pub rows: BTreeMap<(String, Direction), RowCounts>,
    /// Case key -> outcome, for every case scored.
    pub outcomes: BTreeMap<String, Outcome>,
    /// Case key -> its row, `<protocol> <direction>`.
    pub case_rows: BTreeMap<String, String>,
}

fn describe(mismatches: &[Mismatch]) -> String {
    let mut s = String::new();
    for m in mismatches {
        if !s.is_empty() {
            s.push_str("; ");
        }
        s.push_str(&format!("{:?}: expected {:?}, got {:?}", m.field, m.expected, m.actual));
    }
    s
}

impl Report {
    fn record(&mut self, protocol: &str, direction: Direction, key: &str, outcome: Outcome) {
        let row = self
            .rows
            .entry((protocol.to_string(), direction))
            .or_default();
        row.total += 1;
        match &outcome {
            Outcome::Pass => row.pass += 1,
            Outcome::UpstreamSkip => row.upstream_skip += 1,
            Outcome::Refused(name) => *row.refused.entry(name.clone()).or_default() += 1,
            Outcome::Failed(_) => row.failed += 1,
        }
        self.case_rows
            .insert(key.to_string(), format!("{} {}", protocol, direction.as_str()));
        self.outcomes.insert(key.to_string(), outcome);
    }

    /// The ledger text this report satisfies (rows only).
    pub fn to_ledger(&self) -> String {
        let mut s = String::new();
        for ((protocol, direction), c) in &self.rows {
            s.push_str(&format!(
                "{:<10} {:<6} {:>4} {:>4} {:>4} {}\n",
                protocol,
                direction.as_str(),
                c.total,
                c.pass,
                c.upstream_skip,
                refused_token(&c.refused)
            ));
        }
        s
    }
}

fn refused_token(r: &BTreeMap<String, usize>) -> String {
    let parts: Vec<String> = r.iter().map(|(n, c)| format!("{n}={c}")).collect();
    format!("refused[{}]", parts.join(","))
}

/// Score every case of the enabled `protocols` (suite `metadata.protocol`).
/// Order of the verdict: botocore's skip first (an actual for a skipped case
/// is red: the driver and the harness disagree on the skip set), then a
/// refusal record, then the comparison; a case with none of these is red.
pub fn run(
    corpus: &Corpus,
    protocols: &BTreeSet<String>,
    ignore: &IgnoreList,
    actuals: &ActualsFile,
) -> Report {
    let mut report = Report::default();
    for case in corpus.input.iter().filter(|c| protocols.contains(&c.protocol)) {
        let skip = ignore.skips(Direction::Input, &case.file, &case.suite, &case.id);
        let outcome = verdict(
            skip,
            actuals.refused.get(&case.key),
            actuals.input.get(&case.key).map(|a| compare_request(case, a)),
        );
        report.record(&case.protocol, Direction::Input, &case.key, outcome);
    }
    for case in corpus.output.iter().filter(|c| protocols.contains(&c.protocol)) {
        let skip = ignore.skips(Direction::Output, &case.file, &case.suite, &case.id);
        let outcome = verdict(
            skip,
            actuals.refused.get(&case.key),
            actuals.output.get(&case.key).map(|a| compare_response(case, a)),
        );
        report.record(&case.protocol, Direction::Output, &case.key, outcome);
    }
    report
}

fn verdict(skip: bool, refusal: Option<&String>, compared: Option<Vec<Mismatch>>) -> Outcome {
    if skip {
        return if refusal.is_some() || compared.is_some() {
            Outcome::Failed("botocore skips this case, and the driver answered it".into())
        } else {
            Outcome::UpstreamSkip
        };
    }
    if let Some(text) = refusal {
        if compared.is_some() {
            return Outcome::Failed("the case is both refused and answered".into());
        }
        return match refusal_name(text) {
            Some(name) => Outcome::Refused(name),
            None => Outcome::Failed(format!("generation failed without a named refusal: {text}")),
        };
    }
    match compared {
        None => Outcome::Failed("no actual: the generated code raised, or the case was never run".into()),
        Some(m) if m.is_empty() => Outcome::Pass,
        Some(m) => Outcome::Failed(describe(&m)),
    }
}

// ---------------------------------------------------------------------------
// The ledger
// ---------------------------------------------------------------------------

/// A row's columns: `<protocol> <dir> <total> <pass> <upstream_skip>
/// refused[<name>=<n>,...]`. Every case is exactly one of PASS,
/// UPSTREAM-SKIP and REFUSED, so the counts add up to `total`, and there is
/// no column for a failing case: one is red.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LedgerRow {
    pub total: usize,
    pub pass: usize,
    pub upstream_skip: usize,
    pub refused: BTreeMap<String, usize>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LedgerViolation {
    Malformed { line_no: usize, line: String, why: String },
    /// The pinned corpus, or botocore's skip set over it, differs from the row.
    CorpusDrift { row: String, column: &'static str, ledger: usize, actual: usize },
    MissingRow { row: String },
    ExtraRow { row: String },
    /// A case is red (see [`Outcome::Failed`]).
    Failed { row: String, key: String, why: String },
    /// Fewer passes than the row records.
    Regression { row: String, ledger: usize, actual: usize },
    /// A recorded refusal is gone and its cases do not all pass.
    RefusalVanished { row: String, name: String, ledger: usize, actual: usize },
    /// The ledger refuses more than the generator does: shrink the row.
    Stale { row: String, name: String, ledger: usize, actual: usize },
    /// The generator refuses more than the ledger states.
    RefusalGrew { row: String, name: String, ledger: usize, actual: usize },
}

fn malformed(idx: usize, raw: &str, why: &str) -> LedgerViolation {
    LedgerViolation::Malformed {
        line_no: idx + 1,
        line: raw.to_string(),
        why: why.to_string(),
    }
}

fn parse_refused(token: &str) -> Option<BTreeMap<String, usize>> {
    let inner = token.strip_prefix("refused[")?.strip_suffix(']')?;
    let mut out = BTreeMap::new();
    if inner.is_empty() {
        return Some(out);
    }
    for part in inner.split(',') {
        let (name, n) = part.split_once('=')?;
        let n: usize = n.parse().ok()?;
        if n == 0 || refusal_name(&format!("{REFUSAL_MARKER}{name}:")).as_deref() != Some(name) {
            return None;
        }
        if out.insert(name.to_string(), n).is_some() {
            return None;
        }
    }
    Some(out)
}

/// Parse the ledger. `#` starts a comment line; blank lines are ignored.
pub fn parse_ledger(text: &str) -> Result<BTreeMap<String, LedgerRow>, LedgerViolation> {
    let mut rows = BTreeMap::new();
    for (idx, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() != 6 {
            return Err(malformed(idx, raw, "a row has six columns"));
        }
        if f[1] != "input" && f[1] != "output" {
            return Err(malformed(idx, raw, "the direction is `input` or `output`"));
        }
        let nums: Result<Vec<usize>, _> = f[2..5].iter().map(|s| s.parse::<usize>()).collect();
        let nums = nums.map_err(|_| malformed(idx, raw, "total, pass and upstream_skip are numbers"))?;
        let refused = parse_refused(f[5])
            .ok_or_else(|| malformed(idx, raw, "the last column is refused[<name>=<n>,...]"))?;
        let row = LedgerRow {
            total: nums[0],
            pass: nums[1],
            upstream_skip: nums[2],
            refused,
        };
        let sum = row.pass + row.upstream_skip + row.refused.values().sum::<usize>();
        if sum != row.total {
            return Err(malformed(idx, raw, "pass + upstream_skip + refused must equal total"));
        }
        let name = format!("{} {}", f[0], f[1]);
        if rows.insert(name, row).is_some() {
            return Err(malformed(idx, raw, "a row is given twice"));
        }
    }
    Ok(rows)
}

/// Every way the report and the ledger disagree. Empty means green. The
/// check runs in both directions: worse is red, and better is red too until
/// the ledger says so.
pub fn check_ledger(report: &Report, ledger_text: &str) -> Vec<LedgerViolation> {
    let rows = match parse_ledger(ledger_text) {
        Ok(r) => r,
        Err(v) => return vec![v],
    };
    let mut violations = Vec::new();
    for (key, outcome) in &report.outcomes {
        if let Outcome::Failed(why) = outcome {
            let row = report.case_rows.get(key).cloned().unwrap_or_default();
            violations.push(LedgerViolation::Failed {
                row,
                key: key.clone(),
                why: why.clone(),
            });
        }
    }
    let mut seen = BTreeSet::new();
    for ((protocol, direction), c) in &report.rows {
        let name = format!("{} {}", protocol, direction.as_str());
        seen.insert(name.clone());
        let Some(row) = rows.get(&name) else {
            violations.push(LedgerViolation::MissingRow { row: name });
            continue;
        };
        for (column, ledger, actual) in [
            ("total", row.total, c.total),
            ("upstream_skip", row.upstream_skip, c.upstream_skip),
        ] {
            if ledger != actual {
                violations.push(LedgerViolation::CorpusDrift {
                    row: name.clone(),
                    column,
                    ledger,
                    actual,
                });
            }
        }
        if c.pass < row.pass {
            violations.push(LedgerViolation::Regression {
                row: name.clone(),
                ledger: row.pass,
                actual: c.pass,
            });
        }
        let names: BTreeSet<&String> = row.refused.keys().chain(c.refused.keys()).collect();
        for refusal in names {
            let ledger = row.refused.get(refusal).copied().unwrap_or(0);
            let actual = c.refused.get(refusal).copied().unwrap_or(0);
            if actual > ledger {
                violations.push(LedgerViolation::RefusalGrew {
                    row: name.clone(),
                    name: refusal.clone(),
                    ledger,
                    actual,
                });
            } else if actual < ledger {
                // Where did the cases go? To PASS (the ledger is stale), or
                // to red (the refusal vanished and nothing replaced it).
                let v = if c.failed > 0 {
                    LedgerViolation::RefusalVanished {
                        row: name.clone(),
                        name: refusal.clone(),
                        ledger,
                        actual,
                    }
                } else {
                    LedgerViolation::Stale {
                        row: name.clone(),
                        name: refusal.clone(),
                        ledger,
                        actual,
                    }
                };
                violations.push(v);
            }
        }
    }
    for name in rows.keys() {
        if !seen.contains(name) {
            violations.push(LedgerViolation::ExtraRow { row: name.clone() });
        }
    }
    violations
}

// ---------------------------------------------------------------------------
// Unit tests: the loader, the key, the ignore list and every ledger verdict.
// The corpus fragments here are written for these tests; none is copied from
// botocore's corpus.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    const INPUT_FILE: &str = r#"[
      {
        "description": "Suite A",
        "metadata": {"protocol": "json", "jsonVersion": "1.1", "targetPrefix": "Svc"},
        "shapes": {"In": {"type": "structure", "members": {"Name": {"shape": "S"}}},
                   "S": {"type": "string"}},
        "cases": [
          {"id": "SendsName", "given": {"name": "Op", "input": {"shape": "In"}},
           "params": {"Name": "x"},
           "serialized": {"method": "POST", "uri": "/", "body": "{\"Name\": \"x\"}",
                          "headers": {"X-Amz-Target": "Svc.Op"},
                          "requireHeaders": ["Content-Length"],
                          "forbidHeaders": ["X-Forbidden"]}},
          {"id": "SkippedById", "given": {"name": "Op"}, "params": {},
           "serialized": {"method": "POST", "uri": "/", "body": "{}"}}
        ]
      },
      {
        "description": "Skipped suite",
        "metadata": {"protocol": "json"},
        "cases": [
          {"id": "InSkippedSuite", "given": {"name": "Op"}, "params": {},
           "serialized": {"method": "POST", "uri": "/"}}
        ]
      },
      {
        "description": "Other protocol",
        "metadata": {"protocol": "rest-xml"},
        "cases": [
          {"id": "XmlCase", "given": {"name": "Op"}, "params": {},
           "serialized": {"method": "PUT", "uri": "/x", "body": "<A/>",
                          "headers": {"Content-Type": "application/xml"}}}
        ]
      }
    ]"#;

    const OUTPUT_FILE: &str = r#"[
      {
        "description": "Out suite",
        "metadata": {"protocol": "json"},
        "cases": [
          {"id": "ParsesName", "given": {"name": "Op"},
           "response": {"status_code": 200, "headers": {}, "body": "{\"Name\": \"y\"}"},
           "result": {"Name": "y"}},
          {"id": "ParsesError", "given": {"name": "Op"},
           "response": {"status_code": 400, "headers": {"X-Amzn-ErrorType": "Bad"}, "body": "{}"},
           "error": {}, "errorCode": "Bad", "errorMessage": "m"}
        ]
      }
    ]"#;

    const IGNORE: &str = r#"{
      "general": {"input": {"suites": ["Skipped suite"]}},
      "protocols": {"json": {"input": {"cases": ["SkippedById"]}},
                    "json_1_0": {"output": {"cases": ["ParsesName"]}}}
    }"#;

    fn corpus() -> Corpus {
        let mut c = load_file(Direction::Input, "json.json", INPUT_FILE).unwrap();
        c.extend(load_file(Direction::Output, "json.json", OUTPUT_FILE).unwrap());
        c
    }

    fn json_only() -> BTreeSet<String> {
        ["json".to_string()].into_iter().collect()
    }

    fn passing_actuals() -> ActualsFile {
        ActualsFile::parse(
            r#"{"input": {"input/json.json#SendsName": {
                   "method": "POST", "uri": "/", "host": "h", "body": "{\"Name\":\"x\"}",
                   "headers": {"x-amz-target": "Svc.Op", "Content-Length": "12",
                               "Authorization": "AWS4-HMAC-SHA256 ..."}}},
                "output": {"output/json.json#ParsesName": {"result": {"Name": "y"}},
                           "output/json.json#ParsesError": {"errorCode": "Bad", "errorMessage": "m"}}}"#,
        )
        .unwrap()
    }

    const GREEN_LEDGER: &str = "\
# comment
json input 3 1 2 refused[]

json output 2 2 0 refused[]
";

    // ---- loader and key ----------------------------------------------------

    #[test]
    fn loader_keys_are_direction_file_and_id() {
        let c = corpus();
        let keys = c.keys();
        assert_eq!(
            keys,
            vec![
                "input/json.json#SendsName",
                "input/json.json#SkippedById",
                "input/json.json#InSkippedSuite",
                "input/json.json#XmlCase",
                "output/json.json#ParsesName",
                "output/json.json#ParsesError",
            ]
        );
        let unique: BTreeSet<&String> = keys.iter().collect();
        assert_eq!(unique.len(), keys.len());
    }

    #[test]
    fn loader_reads_expectations_and_suite_metadata() {
        let c = corpus();
        let a = &c.input[0];
        assert_eq!(a.protocol, "json");
        assert_eq!(a.suite, "Suite A");
        assert_eq!(a.file, "json.json");
        assert_eq!(a.expected.method.as_deref(), Some("POST"));
        assert_eq!(a.expected.require_headers, vec!["Content-Length"]);
        assert_eq!(a.expected.forbid_headers, vec!["X-Forbidden"]);
        assert_eq!(c.input[3].protocol, "rest-xml");
        let e = &c.output[1];
        assert_eq!(e.response.status_code, 400);
        assert_eq!(
            e.expected,
            ExpectedResult::Error { code: Some("Bad".into()), message: Some("m".into()) }
        );
    }

    #[test]
    fn loader_refuses_a_case_without_an_id() {
        let text = r#"[{"description": "d", "metadata": {"protocol": "json"},
                       "cases": [{"given": {"name": "Op"}, "serialized": {}}]}]"#;
        let e = load_file(Direction::Input, "json.json", text).unwrap_err();
        assert!(e.contains("has no id"), "{e}");
    }

    #[test]
    fn loader_refuses_a_suite_without_a_protocol() {
        let text = r#"[{"description": "d", "metadata": {}, "cases": []}]"#;
        let e = load_file(Direction::Input, "json.json", text).unwrap_err();
        assert!(e.contains("metadata.protocol"), "{e}");
    }

    #[test]
    fn loader_refuses_an_input_case_without_serialized() {
        let text = r#"[{"description": "d", "metadata": {"protocol": "json"},
                       "cases": [{"id": "x", "given": {"name": "Op"}}]}]"#;
        let e = load_file(Direction::Input, "json.json", text).unwrap_err();
        assert!(e.contains("no `serialized`"), "{e}");
    }

    // ---- ignore list -----------------------------------------------------

    #[test]
    fn ignore_list_matches_suites_cases_and_protocol_stems() {
        let ig = IgnoreList::parse(IGNORE).unwrap();
        assert!(ig.skips(Direction::Input, "json.json", "Skipped suite", "anything"));
        assert!(ig.skips(Direction::Input, "rest-xml.json", "Skipped suite", "anything"));
        assert!(!ig.skips(Direction::Output, "json.json", "Skipped suite", "anything"));
        assert!(ig.skips(Direction::Input, "json.json", "Suite A", "SkippedById"));
        // Keyed by the FILE stem, not by the suite's protocol.
        assert!(!ig.skips(Direction::Input, "json_1_0.json", "Suite A", "SkippedById"));
        assert!(ig.skips(Direction::Output, "json_1_0.json", "x", "ParsesName"));
        assert!(!ig.skips(Direction::Output, "json.json", "x", "ParsesName"));
    }

    #[test]
    fn ignore_list_refuses_unknown_keys() {
        assert!(IgnoreList::parse(r#"{"generale": {}}"#).is_err());
        assert!(IgnoreList::parse(r#"{"general": {"inputs": {}}}"#).is_err());
        assert!(IgnoreList::parse(r#"{"general": {"input": {"case": []}}}"#).is_err());
        assert!(IgnoreList::parse(r#"{"general": {"input": {"cases": [1]}}}"#).is_err());
    }

    // ---- refusal names ---------------------------------------------------

    #[test]
    fn refusal_names_are_read_from_the_marker() {
        assert_eq!(refusal_name("REFUSED document: no type").as_deref(), Some("document"));
        assert_eq!(
            refusal_name("suite x: aws front-end: REFUSED event-stream2: why").as_deref(),
            Some("event-stream2")
        );
        assert_eq!(refusal_name("expected a number"), None);
        assert_eq!(refusal_name("REFUSED Document: x"), None);
        assert_eq!(refusal_name("REFUSED document x"), None);
        assert_eq!(refusal_name("REFUSED : x"), None);
    }

    // ---- comparison ------------------------------------------------------

    #[test]
    fn request_headers_are_a_subset_and_case_insensitive() {
        let c = corpus();
        let a = passing_actuals();
        assert!(compare_request(&c.input[0], &a.input["input/json.json#SendsName"]).is_empty());
    }

    #[test]
    fn a_missing_required_header_is_named() {
        let c = corpus();
        let mut a = passing_actuals().input["input/json.json#SendsName"].clone();
        a.headers.retain(|(k, _)| k != "Content-Length");
        let m = compare_request(&c.input[0], &a);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].field, Field::RequiredHeader("Content-Length".into()));
    }

    #[test]
    fn a_forbidden_header_is_named() {
        let c = corpus();
        let mut a = passing_actuals().input["input/json.json#SendsName"].clone();
        a.headers.push(("x-forbidden".into(), "1".into()));
        let m = compare_request(&c.input[0], &a);
        assert_eq!(m[0].field, Field::ForbiddenHeader("X-Forbidden".into()));
    }

    #[test]
    fn json_bodies_compare_as_values() {
        assert!(bodies_equivalent("json", "{\"a\":1,\"b\":[2]}", "{ \"b\": [2], \"a\": 1 }"));
        assert!(!bodies_equivalent("json", "{\"a\":1}", "{\"a\":2}"));
    }

    #[test]
    fn rest_xml_ignores_the_expected_content_type() {
        let c = corpus();
        let a = ActualRequest {
            method: Some("PUT".into()),
            uri: Some("/x".into()),
            body: Some("<A></A>".into()),
            ..Default::default()
        };
        assert!(compare_request(&c.input[3], &a).is_empty());
    }

    // ---- verdicts --------------------------------------------------------

    fn report(actuals: &ActualsFile) -> Report {
        run(&corpus(), &json_only(), &IgnoreList::parse(IGNORE).unwrap(), actuals)
    }

    #[test]
    fn run_scores_only_enabled_protocols() {
        let r = report(&passing_actuals());
        assert_eq!(r.rows.len(), 2);
        assert!(!r.outcomes.contains_key("input/json.json#XmlCase"));
    }

    #[test]
    fn a_green_run_matches_the_ledger() {
        let r = report(&passing_actuals());
        assert_eq!(r.outcomes["input/json.json#SendsName"], Outcome::Pass);
        assert_eq!(r.outcomes["input/json.json#SkippedById"], Outcome::UpstreamSkip);
        assert_eq!(r.outcomes["input/json.json#InSkippedSuite"], Outcome::UpstreamSkip);
        assert_eq!(check_ledger(&r, GREEN_LEDGER), vec![]);
        assert_eq!(r.to_ledger().lines().count(), 2);
        assert_eq!(check_ledger(&r, &r.to_ledger()), vec![]);
    }

    #[test]
    fn an_answer_for_a_skipped_case_is_red() {
        let mut a = passing_actuals();
        let extra = a.input["input/json.json#SendsName"].clone();
        a.input.insert("input/json.json#SkippedById".into(), extra);
        let r = report(&a);
        assert!(matches!(r.outcomes["input/json.json#SkippedById"], Outcome::Failed(_)));
    }

    #[test]
    fn a_missing_answer_is_red() {
        let mut a = passing_actuals();
        a.output.remove("output/json.json#ParsesError");
        let v = check_ledger(&report(&a), GREEN_LEDGER);
        assert!(v.iter().any(|x| matches!(x, LedgerViolation::Failed { key, .. }
            if key == "output/json.json#ParsesError")));
        assert!(v.iter().any(|x| matches!(x, LedgerViolation::Regression { ledger: 2, actual: 1, .. })));
    }

    #[test]
    fn a_wrong_answer_is_red_and_says_why() {
        let mut a = passing_actuals();
        a.output.insert(
            "output/json.json#ParsesName".into(),
            ActualResponse::Success(parse_json("{\"Name\": \"z\"}").unwrap()),
        );
        let r = report(&a);
        match &r.outcomes["output/json.json#ParsesName"] {
            Outcome::Failed(why) => assert!(why.contains("Result"), "{why}"),
            o => panic!("{o:?}"),
        }
    }

    #[test]
    fn an_unnamed_generation_error_is_red() {
        let mut a = passing_actuals();
        a.input.remove("input/json.json#SendsName");
        a.refused.insert("input/json.json#SendsName".into(), "expected a number".into());
        let r = report(&a);
        assert!(matches!(&r.outcomes["input/json.json#SendsName"], Outcome::Failed(w)
            if w.contains("without a named refusal")));
    }

    #[test]
    fn a_case_both_refused_and_answered_is_red() {
        let mut a = passing_actuals();
        a.refused.insert("input/json.json#SendsName".into(), "REFUSED document: x".into());
        let r = report(&a);
        assert!(matches!(r.outcomes["input/json.json#SendsName"], Outcome::Failed(_)));
    }

    fn refusing_actuals() -> ActualsFile {
        let mut a = passing_actuals();
        a.input.remove("input/json.json#SendsName");
        a.refused.insert(
            "input/json.json#SendsName".into(),
            "aws front-end: REFUSED document: shape `D`".into(),
        );
        a
    }

    const REFUSING_LEDGER: &str = "\
json input 3 0 2 refused[document=1]
json output 2 2 0 refused[]
";

    #[test]
    fn a_named_refusal_matches_its_row() {
        let r = report(&refusing_actuals());
        assert_eq!(r.outcomes["input/json.json#SendsName"], Outcome::Refused("document".into()));
        assert_eq!(check_ledger(&r, REFUSING_LEDGER), vec![]);
        assert_eq!(check_ledger(&r, &r.to_ledger()), vec![]);
    }

    #[test]
    fn violation_refusal_grew() {
        let v = check_ledger(&report(&refusing_actuals()), GREEN_LEDGER);
        assert!(v.contains(&LedgerViolation::RefusalGrew {
            row: "json input".into(),
            name: "document".into(),
            ledger: 0,
            actual: 1
        }));
        assert!(v.iter().any(|x| matches!(x, LedgerViolation::Regression { .. })));
    }

    #[test]
    fn violation_stale() {
        let v = check_ledger(&report(&passing_actuals()), REFUSING_LEDGER);
        assert_eq!(
            v,
            vec![LedgerViolation::Stale {
                row: "json input".into(),
                name: "document".into(),
                ledger: 1,
                actual: 0
            }]
        );
    }

    #[test]
    fn violation_refusal_vanished() {
        let mut a = passing_actuals();
        a.input.remove("input/json.json#SendsName");
        let v = check_ledger(&report(&a), REFUSING_LEDGER);
        assert!(v.contains(&LedgerViolation::RefusalVanished {
            row: "json input".into(),
            name: "document".into(),
            ledger: 1,
            actual: 0
        }));
    }

    #[test]
    fn violation_regression() {
        let mut a = passing_actuals();
        a.output.insert(
            "output/json.json#ParsesError".into(),
            ActualResponse::Error { code: Some("Other".into()), message: Some("m".into()) },
        );
        let v = check_ledger(&report(&a), GREEN_LEDGER);
        assert!(v.contains(&LedgerViolation::Regression {
            row: "json output".into(),
            ledger: 2,
            actual: 1
        }));
    }

    #[test]
    fn violation_corpus_drift_on_total_and_skip() {
        let r = report(&passing_actuals());
        let v = check_ledger(&r, "json input 4 1 3 refused[]\njson output 2 2 0 refused[]\n");
        assert!(v.contains(&LedgerViolation::CorpusDrift {
            row: "json input".into(),
            column: "total",
            ledger: 4,
            actual: 3
        }));
        assert!(v.contains(&LedgerViolation::CorpusDrift {
            row: "json input".into(),
            column: "upstream_skip",
            ledger: 3,
            actual: 2
        }));
    }

    #[test]
    fn violation_missing_and_extra_rows() {
        let r = report(&passing_actuals());
        let v = check_ledger(&r, "json input 3 1 2 refused[]\nquery input 1 1 0 refused[]\n");
        assert!(v.contains(&LedgerViolation::MissingRow { row: "json output".into() }));
        assert!(v.contains(&LedgerViolation::ExtraRow { row: "query input".into() }));
    }

    #[test]
    fn violation_malformed() {
        let r = report(&passing_actuals());
        for bad in [
            "json input 3 1 2\n",
            "json sideways 3 1 2 refused[]\n",
            "json input three 1 2 refused[]\n",
            "json input 3 1 1 refused[]\n",
            "json input 3 0 2 refused[document]\n",
            "json input 3 0 2 refused[Document=1]\n",
            "json input 3 1 2 refused[document=0]\n",
            "json input 3 1 2 refused[]\njson input 3 1 2 refused[]\n",
        ] {
            let v = check_ledger(&r, bad);
            assert!(
                matches!(v.as_slice(), [LedgerViolation::Malformed { .. }]),
                "{bad:?} -> {v:?}"
            );
        }
    }
}
