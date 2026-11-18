//! Self-improvement memory: how Murmur's commands learn from their own mistakes, and keep track of whether what they
//! learned helps, as the Mac's SelfImprovement.swift. After "Self-Improvement Memory Enables Continual Recursive
//! Self-Improvement" (Google Cloud AI and Google DeepMind, 2026): the whole record is kept, not only the latest rule.
//! Each problem is keyed by its root cause, with every rule tried for it, why, what it was predicted to fix (written
//! before it's tried), what happened since and with which model. Rules that didn't help are kept too, marked.
//!
//! - A command that went wrong (steps that failed, an early finish Murmur sent back, going round in circles, being
//!   stopped, or you correcting it straight after: "no, I meant…") is a run to learn from.
//! - The commands' AI (a cloud one) reads that run and the whole memory, names the root cause (one already here, or a
//!   new one) and proposes a rule, with its reason, when it applies, and a prediction.
//! - The rule goes into the instructions for matching commands; each time, whether the command then worked is kept,
//!   with the model.
//! - The evidence decides: a rule that hasn't helped with a model is turned off for it; one that hasn't helped at all
//!   is retired, and the next problem of that kind gets a revised rule that sees why. Only you delete (Settings).
//!
//! On this PC only (self-improvement.json beside the settings), at most 60 problems.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

/// When a rule applies: in these apps, or for requests with these words. Both empty: every command.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Scope {
    #[serde(default)]
    pub apps: Vec<String>,
    #[serde(default)]
    pub words: Vec<String>,
}

/// One command a rule was applied to, and whether it then worked.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Observation {
    pub at: f64,
    pub model: String,
    pub worked: bool,
    pub request: String,
}

/// One fix tried for a problem.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Attempt {
    pub id: String,
    pub rule: String,
    pub rationale: String,
    pub scope: Scope,
    pub prediction: String,
    /// Where it came from: the model and app of the run that showed the problem, when, and which round.
    pub model: String,
    pub app: String,
    pub created: f64,
    pub round: u32,
    pub trigger: String,
    #[serde(default)]
    pub observed: Vec<Observation>,
    /// Why it's no longer used (None while it is).
    #[serde(default)]
    pub retired: Option<String>,
    /// Models it's off for, because it didn't help there.
    #[serde(default)]
    pub not_for: Vec<String>,
}

impl Attempt {
    /// (worked, of): with one model, or all.
    pub fn tally(&self, model: Option<&str>) -> (usize, usize) {
        let seen: Vec<&Observation> = self.observed.iter().filter(|o| model.is_none_or(|m| o.model == m)).collect();
        (seen.iter().filter(|o| o.worked).count(), seen.len())
    }
}

/// A recurring problem, keyed by its root cause, with every fix tried for it in order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Problem {
    pub id: String,
    pub root_cause: String,
    pub attempts: Vec<Attempt>,
}

impl Problem {
    /// The fix in use (the latest one not retired).
    pub fn current(&self) -> Option<&Attempt> {
        self.attempts.iter().rev().find(|a| a.retired.is_none())
    }
}

/// A rule in use for a command.
#[derive(Clone, Debug, PartialEq)]
pub struct Lesson {
    pub problem: String,
    pub attempt: String,
    pub rule: String,
}

/// What the AI proposes after reading a run that went wrong and the whole memory.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Proposal {
    pub add: bool,
    pub root_cause: String,
    pub rule: String,
    pub rationale: String,
    pub scope: Scope,
    pub prediction: String,
    /// Earlier attempts the evidence says to stop using, with why.
    pub retire: Vec<(String, String)>,
}

/// A command as Murmur saw it.
#[derive(Clone, Debug, Default)]
pub struct Run {
    pub request: String,
    pub app: Option<String>,
    pub window: Option<String>,
    pub model: String,
    /// (tool, what it did, whether it worked).
    pub steps: Vec<(String, String, bool)>,
    /// Times Murmur sent the model back, or stopped it, and why.
    pub sent_back: Vec<String>,
    pub stopped: bool,
    pub answer: Option<String>,
    /// What you said next, when it corrected this command.
    pub correction: Option<String>,
    pub lessons: Vec<Lesson>,
}

impl Run {
    /// Corrected, stopped, sent back, or more than one failed step (one failed step worked around is normal).
    pub fn went_wrong(&self) -> bool {
        self.correction.is_some() || self.stopped || !self.sent_back.is_empty() || self.steps.iter().filter(|s| !s.2).count() >= 2
    }

    /// The run as the AI reads it.
    pub fn report(&self) -> String {
        let mut text = format!("Request: \"{}\"\nIn: {}{}\nModel: {}\n", self.request, self.app.as_deref().unwrap_or("?"),
                               self.window.as_deref().map(|w| format!(" — {}", crate::ai::cut(w, 80))).unwrap_or_default(), self.model);
        if !self.lessons.is_empty() {
            text += &format!("Rules it was given: {}\n", self.lessons.iter().map(|l| format!("[{}] {}", l.attempt, l.rule)).collect::<Vec<_>>().join(" | "));
        }
        text += "Steps:\n";
        if self.steps.is_empty() {
            text += "  (none)\n";
        }
        for (tool, said, worked) in self.steps.iter().rev().take(30).collect::<Vec<_>>().into_iter().rev() {
            text += &format!("  {} {tool}: {}\n", if *worked { "ok" } else { "FAILED" }, crate::ai::cut(said, 160));
        }
        if !self.sent_back.is_empty() {
            text += &format!("Sent back before finishing: {}\n", self.sent_back.join("; "));
        }
        if self.stopped {
            text += "The task was stopped before it finished.\n";
        }
        if let Some(answer) = &self.answer {
            text += &format!("Answer shown: {}\n", crate::ai::cut(answer, 300));
        }
        if let Some(correction) = &self.correction {
            text += &format!("The user's next words, correcting it: \"{correction}\"\n");
        }
        text
    }
}

/// Whether a tool's result says it didn't work.
pub fn failed(result: &str) -> bool {
    let lower = result.trim().to_lowercase();
    ["couldn't", "can't ", "cannot ", "unknown tool", "isn't available", "not available", "failed", "error", "no app called",
     "not found", "nothing matched", "didn't work"].iter().any(|sign| lower.starts_with(sign) || lower.contains(&format!(" {sign}")))
        && !lower.starts_with("done")
}

/// Whether what you said right after a command corrects it: "no, I meant…", "that's wrong", "try again".
pub fn is_correction(said: &str) -> bool {
    static PATTERN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    PATTERN.get_or_init(|| regex::Regex::new(r"^(no\b|nope\b|not that|not this|wrong|that'?s (not|wrong)|that is (not|wrong)|you (didn'?t|did not|missed|forgot)|i (said|meant|asked)|try again|do it again|that didn'?t work|it didn'?t|it did not|still (not|didn'?t|wrong)|undo)").unwrap())
        .is_match(said.trim().to_lowercase().as_str())
}

pub const REFLECT_SYSTEM: &str = "You improve Murmur, a Windows assistant that does what its user asks by calling tools \
(opening apps and pages, typing, pressing keys, running commands, finding files). A command just went wrong. You get the \
run, and Murmur's self-improvement memory: every earlier problem, each rule tried for it, why, what it was predicted to \
fix, and what actually happened since, by model. Use that evidence: a rule that was applied in this run and failed anyway, \
or that worked for one model and not another, should be revised, not repeated.
1. Diagnose the root cause: what in Murmur's approach went wrong (not the user's fault, not a one-off outage). If it is one \
of the memory's root causes, cite it with exactly the same words; otherwise name a new one in a short reusable phrase \
(like \"finishes before entering the answer\").
2. Propose one rule for Murmur to follow from now on: one or two imperative sentences, specific and checkable, general \
enough to help other requests of this kind, with no private details (names, messages, numbers from this run).
3. Say when it applies: app names, and/or two to five words that requests of this kind contain.
4. Predict, before it's tried, which future requests it will fix and what will go differently.
5. If the evidence shows an earlier rule hurting, list it in \"retire\" with why.
If no rule could have prevented this (no network, a missing permission, the user changed their mind), reply with \
\"action\": \"none\".
Reply with JSON only:
{\"action\": \"add\" or \"none\", \"root_cause\": \"...\", \"rule\": \"...\", \"rationale\": \"...\", \"scope\": {\"apps\": \
[\"...\"], \"words\": [\"...\"]}, \"prediction\": \"...\", \"retire\": [{\"id\": \"...\", \"why\": \"...\"}]}";

/// The AI's reply, read: the JSON object in it (code fences and stray text around it are fine).
pub fn proposal(reply: &str) -> Option<Proposal> {
    let start = reply.find('{')?;
    let end = reply.rfind('}')?;
    if end <= start {
        return None;
    }
    let json: Value = serde_json::from_str(&reply[start..=end]).ok()?;
    let text = |key: &str| json[key].as_str().unwrap_or_default().trim().to_string();
    let list = |key: &str| json["scope"][key].as_array().map(|items| items.iter()
        .filter_map(|v| v.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()).unwrap_or_default();
    let retire = json["retire"].as_array().map(|items| items.iter().filter_map(|item| {
        let id = item["id"].as_str()?.trim();
        (!id.is_empty()).then(|| (id.to_string(), item["why"].as_str().unwrap_or_default().to_string()))
    }).collect()).unwrap_or_default();
    Some(Proposal {
        add: text("action").to_lowercase() == "add", root_cause: text("root_cause"), rule: text("rule"),
        rationale: text("rationale"), scope: Scope { apps: list("apps"), words: list("words") },
        prediction: text("prediction"), retire,
    })
}

fn key(cause: &str) -> String {
    cause.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect::<Vec<_>>().join("-")
}

fn words(text: &str) -> HashSet<String> {
    text.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(String::from).collect()
}

const KEEP_PROBLEMS: usize = 60;

pub struct Improvement {
    file: Option<PathBuf>,
    store: Mutex<Vec<Problem>>,
}

impl Improvement {
    pub fn open(file: Option<PathBuf>) -> Improvement {
        let store = file.as_ref().and_then(|f| std::fs::read(f).ok())
            .and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        Improvement { file, store: Mutex::new(store) }
    }

    pub fn problems(&self) -> Vec<Problem> {
        self.store.lock().unwrap().clone()
    }

    fn save(&self) {
        let Some(file) = &self.file else { return };
        let data = serde_json::to_vec_pretty(&*self.store.lock().unwrap()).unwrap_or_default();
        if let Some(folder) = file.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        let temporary = file.with_extension("json.new");
        if std::fs::write(&temporary, data).is_ok() {
            let _ = std::fs::rename(temporary, file);
        }
    }

    /// The rules for a command: the problems' current fixes whose scope matches the request or the app, not turned off
    /// for this model, the best-proven first.
    pub fn lessons(&self, request: &str, app: Option<&str>, model: &str, limit: usize) -> Vec<Lesson> {
        let said = words(request);
        let app = app.unwrap_or_default().to_lowercase();
        let store = self.store.lock().unwrap();
        let mut found: Vec<(Lesson, i64)> = store.iter().filter_map(|problem| {
            let attempt = problem.current()?;
            if attempt.not_for.iter().any(|m| m == model) {
                return None;
            }
            let by_app = !app.is_empty() && attempt.scope.apps.iter().any(|a| !a.is_empty() && app.contains(&a.to_lowercase()));
            let by_words = attempt.scope.words.iter().any(|w| {
                let parts = words(w);
                !parts.is_empty() && parts.iter().all(|p| said.contains(p))
            });
            let everywhere = attempt.scope.apps.is_empty() && attempt.scope.words.is_empty();
            if !(by_app || by_words || everywhere) {
                return None;
            }
            let (worked, of) = attempt.tally(None);
            Some((Lesson { problem: problem.id.clone(), attempt: attempt.id.clone(), rule: attempt.rule.clone() },
                  worked as i64 * 2 - of as i64))
        }).collect();
        found.sort_by(|a, b| b.1.cmp(&a.1));
        found.into_iter().take(limit).map(|(lesson, _)| lesson).collect()
    }

    /// The rules, as they go into the instructions.
    pub fn prompt(lessons: &[Lesson]) -> Option<String> {
        if lessons.is_empty() {
            return None;
        }
        Some(format!("Rules Murmur learned from its own earlier mistakes on tasks like this (follow them unless the user's \
                      request says otherwise):\n{}", lessons.iter().map(|l| format!("- {}", l.rule)).collect::<Vec<_>>().join("\n")))
    }

    /// Records how a command went for each rule it used, and lets the evidence decide. Returns what changed, for the log.
    pub fn observe(&self, lessons: &[Lesson], worked: bool, model: &str, request: &str, at: f64) -> Vec<String> {
        if lessons.is_empty() {
            return vec![];
        }
        let mut changes = vec![];
        {
            let mut store = self.store.lock().unwrap();
            for lesson in lessons {
                let Some(p) = store.iter().position(|p| p.id == lesson.problem) else { continue };
                let Some(a) = store[p].attempts.iter().position(|a| a.id == lesson.attempt) else { continue };
                store[p].attempts[a].observed.push(Observation { at, model: model.into(), worked, request: crate::ai::cut(request, 120) });
                changes.extend(judge(&mut store[p].attempts[a], model));
            }
        }
        self.save();
        changes
    }

    /// A command that looked fine was corrected straight after: its observations become "didn't work".
    pub fn correct(&self, lessons: &[Lesson], model: &str, request: &str) -> Vec<String> {
        if lessons.is_empty() {
            return vec![];
        }
        let request = crate::ai::cut(request, 120);
        let mut changes = vec![];
        {
            let mut store = self.store.lock().unwrap();
            for lesson in lessons {
                let Some(p) = store.iter().position(|p| p.id == lesson.problem) else { continue };
                let Some(a) = store[p].attempts.iter().position(|a| a.id == lesson.attempt) else { continue };
                let attempt = &mut store[p].attempts[a];
                if let Some(o) = attempt.observed.iter().rposition(|o| o.request == request && o.model == model) {
                    attempt.observed[o].worked = false;
                    changes.extend(judge(attempt, model));
                }
            }
        }
        self.save();
        changes
    }

    /// Adds a proposal: under the root cause it cites (merged when it's the same words), or a new one. A current rule
    /// for that root cause is retired as revised (its history stays). Returns what changed.
    pub fn learn(&self, proposal: &Proposal, request: &str, app: Option<&str>, model: &str, at: f64) -> Vec<String> {
        let mut changes = vec![];
        {
            let mut store = self.store.lock().unwrap();
            for (id, why) in &proposal.retire {
                for problem in store.iter_mut() {
                    if let Some(attempt) = problem.attempts.iter_mut().find(|a| &a.id == id && a.retired.is_none()) {
                        attempt.retired = Some(format!("retired after review: {why}"));
                        changes.push(format!("retired: {}", attempt.rule));
                    }
                }
            }
            let rule = proposal.rule.trim();
            let cause = proposal.root_cause.trim();
            if proposal.add && !rule.is_empty() && !cause.is_empty() {
                let id = key(cause);
                let round = store.iter().flat_map(|p| p.attempts.iter()).map(|a| a.round).max().unwrap_or(0) + 1;
                let attempt = Attempt {
                    id: format!("a{round}-{}", at as u64 % 100_000), rule: rule.into(), rationale: proposal.rationale.clone(),
                    scope: proposal.scope.clone(), prediction: proposal.prediction.clone(), model: model.into(),
                    app: app.unwrap_or_default().into(), created: at, round, trigger: crate::ai::cut(request, 160),
                    observed: vec![], retired: None, not_for: vec![],
                };
                match store.iter().position(|p| key(&p.root_cause) == id || p.id == id) {
                    Some(p) => {
                        let same = store[p].current().is_some_and(|a| a.rule == rule);
                        if !same {
                            if let Some(current) = store[p].attempts.iter_mut().rev().find(|a| a.retired.is_none()) {
                                current.retired = Some(format!("revised after it didn't prevent: {}", crate::ai::cut(request, 80)));
                            }
                            store[p].attempts.push(attempt);
                            changes.push(format!("revised \"{}\": {rule}", store[p].root_cause));
                        }
                    }
                    None => {
                        store.push(Problem { id, root_cause: cause.into(), attempts: vec![attempt] });
                        changes.push(format!("learned \"{cause}\": {rule}"));
                    }
                }
                // Small: the problems not touched for longest go first.
                if store.len() > KEEP_PROBLEMS {
                    store.sort_by(|a, b| {
                        let last = |p: &Problem| p.attempts.last().map_or(0.0, |a| a.created);
                        last(b).partial_cmp(&last(a)).unwrap_or(std::cmp::Ordering::Equal)
                    });
                    store.truncate(KEEP_PROBLEMS);
                }
            }
        }
        self.save();
        changes
    }

    pub fn forget(&self, problem: &str) {
        self.store.lock().unwrap().retain(|p| p.id != problem);
        self.save();
    }

    pub fn forget_all(&self) {
        self.store.lock().unwrap().clear();
        self.save();
    }

    /// Every problem with its full history, newest problems first, cut to `limit` characters.
    pub fn rendered(&self, limit: usize, now: f64) -> String {
        let store = self.store.lock().unwrap();
        if store.is_empty() {
            return "(empty: nothing learned yet)".into();
        }
        let mut out = String::new();
        for problem in store.iter().rev() {
            let mut block = format!("Root cause: {}\n", problem.root_cause);
            for (index, attempt) in problem.attempts.iter().enumerate() {
                let (worked, of) = attempt.tally(None);
                let mut models: Vec<String> = attempt.observed.iter().map(|o| o.model.clone()).collect::<HashSet<_>>().into_iter().collect();
                models.sort();
                let by_model = models.iter().map(|m| { let (w, o) = attempt.tally(Some(m)); format!("{m} {w}/{o}") }).collect::<Vec<_>>().join(", ");
                block += &format!("  Attempt {} [id {}], round {}, {} days ago, from a run with {} in {} (\"{}\"):\n", index + 1, attempt.id,
                                  attempt.round, ((now - attempt.created) / 86_400.0).max(0.0) as u64, attempt.model,
                                  if attempt.app.is_empty() { "?" } else { &attempt.app }, crate::ai::cut(&attempt.trigger, 80));
                block += &format!("    Rule: {}\n    Why: {}\n", attempt.rule, attempt.rationale);
                block += &format!("    Applies: apps {}; words {}\n", attempt.scope.apps.join(", "), attempt.scope.words.join(", "));
                block += &format!("    Predicted: {}\n", attempt.prediction);
                block += &format!("    Observed: {}\n", if of == 0 { "not applied yet".to_string() } else { format!("worked {worked} of {of} ({by_model})") });
                if !attempt.not_for.is_empty() {
                    block += &format!("    Off for: {}\n", attempt.not_for.join(", "));
                }
                block += &format!("    Status: {}\n", attempt.retired.as_deref().unwrap_or("in use"));
            }
            if out.chars().count() + block.chars().count() > limit {
                break;
            }
            out += &block;
        }
        out
    }

    /// The request to the AI after a run went wrong: the run, and the whole memory.
    pub fn reflection(&self, run: &Run, now: f64) -> String {
        format!("The run that went wrong:\n{}\nMurmur's self-improvement memory:\n{}", run.report(), self.rendered(12_000, now))
    }
}

/// The selector, for one attempt: off for a model it hasn't helped (under half, in 3 or more tries with it), retired
/// when it hasn't helped at all (under half, in 4 or more tries).
fn judge(attempt: &mut Attempt, model: &str) -> Vec<String> {
    let mut changes = vec![];
    let (worked, of) = attempt.tally(Some(model));
    if of >= 3 && (worked as f64) / (of as f64) < 0.5 && !attempt.not_for.iter().any(|m| m == model) {
        attempt.not_for.push(model.into());
        changes.push(format!("off for {model} (worked {worked} of {of}): {}", attempt.rule));
    }
    let (worked, of) = attempt.tally(None);
    if attempt.retired.is_none() && of >= 4 && (worked as f64) / (of as f64) < 0.5 {
        attempt.retired = Some(format!("didn't help: worked {worked} of {of} times"));
        changes.push(format!("retired (worked {worked} of {of}): {}", attempt.rule));
    }
    changes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proposal(cause: &str, rule: &str, apps: &[&str], words: &[&str]) -> Proposal {
        Proposal { add: true, root_cause: cause.into(), rule: rule.into(), rationale: "because".into(),
                   scope: Scope { apps: apps.iter().map(|s| s.to_string()).collect(), words: words.iter().map(|s| s.to_string()).collect() },
                   prediction: "fixes it".into(), retire: vec![] }
    }

    #[test]
    fn learns_scopes_and_keeps_it() {
        let file = std::env::temp_dir().join(format!("murmur-improve-{}.json", std::process::id()));
        let memory = Improvement::open(Some(file.clone()));
        assert_eq!(memory.learn(&proposal("Finishes before typing", "Type it before done.", &["notepad"], &["write"]), "write a note", Some("notepad"), "m", 1.0).len(), 1);
        assert_eq!(memory.lessons("write to John", Some("chrome"), "m", 6).len(), 1);
        assert_eq!(memory.lessons("open it", Some("Notepad"), "m", 6).len(), 1);
        assert_eq!(memory.lessons("open it", Some("chrome"), "m", 6).len(), 0);
        assert_eq!(memory.lessons("writing", None, "m", 6).len(), 0);
        assert_eq!(Improvement::open(Some(file.clone())).problems().len(), 1);
        let _ = std::fs::remove_file(file);
    }

    #[test]
    fn merges_revises_and_keeps_history() {
        let memory = Improvement::open(None);
        memory.learn(&proposal("Finishes early", "Rule one.", &[], &[]), "a", None, "m", 1.0);
        memory.learn(&proposal("finishes  early!", "Rule one.", &[], &[]), "b", None, "m", 2.0);
        assert_eq!(memory.problems()[0].attempts.len(), 1);
        memory.learn(&proposal("Finishes early", "Rule two.", &[], &[]), "c", None, "m", 3.0);
        let problems = memory.problems();
        assert_eq!(problems.len(), 1);
        assert_eq!(problems[0].attempts.len(), 2);
        assert!(problems[0].attempts[0].retired.is_some());
        assert_eq!(problems[0].current().unwrap().rule, "Rule two.");
        assert!(memory.rendered(12_000, 10.0).contains("Rule one."));
    }

    #[test]
    fn the_selector_goes_by_model() {
        let memory = Improvement::open(None);
        memory.learn(&proposal("x", "Do x.", &[], &[]), "a", None, "m", 1.0);
        let lessons = memory.lessons("anything", None, "haiku", 6);
        for _ in 0..3 { memory.observe(&lessons, false, "haiku", "r", 2.0); }
        assert!(memory.lessons("anything", None, "haiku", 6).is_empty());
        assert_eq!(memory.lessons("anything", None, "sonnet", 6).len(), 1);
        memory.observe(&lessons, false, "sonnet", "r", 3.0);
        assert!(memory.problems()[0].current().is_none());
        assert_eq!(memory.problems()[0].attempts.len(), 1);
        // A correction flips the last observation.
        let memory = Improvement::open(None);
        memory.learn(&proposal("y", "Do y.", &[], &[]), "a", None, "m", 1.0);
        let lessons = memory.lessons("q", None, "m", 6);
        memory.observe(&lessons, true, "m", "send it", 2.0);
        memory.correct(&lessons, "m", "send it");
        assert_eq!(memory.problems()[0].attempts[0].tally(None), (0, 1));
    }

    #[test]
    fn replies_runs_and_corrections() {
        let reply = "```json\n{\"action\": \"add\", \"root_cause\": \"Opens without typing\", \"rule\": \"Type it.\", \"scope\": {\"apps\": [\"notepad\", \"\"]}, \"retire\": [{\"id\": \"a1-5\", \"why\": \"w\"}, {\"x\": 1}]}\n```";
        let read = super::proposal(reply).unwrap();
        assert!(read.add);
        assert_eq!(read.scope.apps, vec!["notepad"]);
        assert_eq!(read.retire.len(), 1);
        assert!(!super::proposal(r#"{"action":"none"}"#).unwrap().add);
        assert!(super::proposal("nothing").is_none());
        assert!(is_correction("No, I meant the other file"));
        assert!(is_correction("you didn't send it"));
        assert!(!is_correction("note the meeting"));
        let mut run = Run { request: "r".into(), model: "m".into(), steps: vec![("open_app".into(), "x".into(), false)], ..Default::default() };
        assert!(!run.went_wrong());
        run.sent_back.push("finished early".into());
        assert!(run.went_wrong());
        assert!(failed("Couldn't find an app called Foo."));
        assert!(failed("Unknown tool frob."));
        assert!(!failed("Opened Spotify."));
    }
}
