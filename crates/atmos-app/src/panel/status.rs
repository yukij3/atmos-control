//! What the panel says about the engine, derived from one snapshot: the four status rows and
//! the notices with their recovery actions. Pure (no Rune), so the wording and the state
//! mapping are tested here and the view only lays them out.
//!
//! Every row pairs its text with a shape ([`Mark`]): a filled dot for live, a hollow ring for
//! idle, a turning ring while busy, a warning triangle for a problem. Colour only reinforces it.

use atmos_core::{CaptureMode, EngineStatus, HeadTrackState, HrtfState, Snapshot};

/// The shape cue beside a status value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mark {
    /// Engaged: filled accent dot (the radar's live-source mark).
    Live,
    /// Not engaged: hollow ring.
    Idle,
    /// A start or stop in flight: a turning ring (still under Reduce Motion).
    Busy,
    /// Blocked until the user acts (permission, driver): orange triangle.
    Warn,
    /// A failure: red triangle.
    Error,
}

/// One status row's value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub value: String,
    pub mark: Option<Mark>,
    /// Tooltip and accessible description: why the value is what it is.
    pub help: String,
    /// A reason shown under the row (HRTF when generic: the honest why).
    pub caption: Option<String>,
}

/// A recovery action a notice offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// System Settings ▸ Privacy & Security, audio capture.
    OpenPrivacy,
    /// Retry the tap after a permission failure (doesn't change routing).
    RetryCapture,
    /// Turn the engine on again after a failed start.
    StartAgain,
    /// Switch to the capture that needs no driver.
    UsePersonalized,
}

impl Action {
    pub fn label(self) -> &'static str {
        match self {
            Action::OpenPrivacy => "Open Privacy Settings",
            Action::RetryCapture | Action::StartAgain => "Try Again",
            Action::UsePersonalized => "Use Personalized Capture",
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            Action::OpenPrivacy => "open-privacy",
            Action::RetryCapture => "retry-capture",
            Action::StartAgain => "start-again",
            Action::UsePersonalized => "use-personalized",
        }
    }
}

/// What kind of notice: picks its icon and ink.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoticeKind {
    /// Waiting on the macOS prompt: lock, secondary ink (nothing is wrong yet).
    Pending,
    /// Audio capture denied: lock, orange.
    Permission,
    /// The current capture can't run (driver missing): triangle, orange.
    Blocked,
    /// A start failed: triangle, red.
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notice {
    pub key: &'static str,
    pub kind: NoticeKind,
    /// Names the problem.
    pub title: String,
    /// Names the way out, when the actions alone don't.
    pub detail: Option<String>,
    pub actions: Vec<Action>,
}

/// Everything the status area shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    pub engine: Line,
    pub output: Line,
    pub hrtf: Line,
    pub head: Line,
    pub notices: Vec<Notice>,
    /// Apple Music advice while the surround capture runs (information, not a problem).
    pub advisory: Option<String>,
}

impl Model {
    pub fn new(s: &Snapshot) -> Model {
        let mut notices = Vec::new();
        // A start the engine says more about than "Starting…": a Personalized start blocked on
        // the macOS audio-capture prompt reads "Awaiting capture permission…" after
        // 1.5 s (still busy). The engine's own words head the notice.
        let waiting = waiting_detail(s);
        if let Some(text) = &waiting {
            let consent = text.to_lowercase().contains("permission");
            notices.push(Notice {
                key: "notice-waiting",
                kind: NoticeKind::Pending,
                title: text.clone(),
                detail: consent.then(|| "Answer the macOS prompt, or allow atmos-control in Privacy & Security.".into()),
                actions: if consent { vec![Action::OpenPrivacy] } else { Vec::new() },
            });
        }
        let waiting = waiting.is_some();
        let idle = !s.is_on && !s.busy;
        if idle && s.permission_needed {
            notices.push(Notice {
                key: "notice-permission",
                kind: NoticeKind::Permission,
                title: "Audio capture isn’t allowed.".into(),
                detail: Some("Allow atmos-control in System Settings ▸ Privacy & Security, then try again.".into()),
                actions: vec![Action::OpenPrivacy, Action::RetryCapture],
            });
        }
        if idle && !s.can_run {
            notices.push(Notice {
                key: "notice-driver",
                kind: NoticeKind::Blocked,
                title: format!("{} needs the atmos-control driver, which isn’t installed.", s.capture_choice.label()),
                detail: None,
                actions: vec![Action::UsePersonalized],
            });
        }
        if let Some(err) = s.last_error.as_deref().filter(|_| !s.busy) {
            notices.push(Notice {
                key: "notice-error",
                kind: NoticeKind::Failed,
                title: err.to_owned(),
                detail: None,
                actions: if s.is_on || !s.can_run { Vec::new() } else { vec![Action::StartAgain] },
            });
        }

        Model {
            engine: engine_line(s, waiting),
            output: output_line(s),
            hrtf: hrtf_line(s),
            head: head_line(s),
            notices,
            advisory: s.music_atmos_advisory.clone().filter(|_| s.is_on),
        }
    }
}

fn line(value: impl Into<String>, mark: Option<Mark>, help: impl Into<String>) -> Line {
    Line { value: value.into(), mark, help: help.into(), caption: None }
}

/// The power switch's text pair. A start the engine says more about keeps the short
/// "Starting…" here; the notice below carries the engine's words.
fn engine_line(s: &Snapshot, waiting: bool) -> Line {
    match s.engine_status {
        EngineStatus::Starting if waiting => line("Starting…", Some(Mark::Busy), s.engine_status_text.clone()),
        EngineStatus::Starting => line("Starting…", Some(Mark::Busy), "Starting the spatializer."),
        EngineStatus::Stopping => line("Stopping…", Some(Mark::Busy), "Stopping; system audio returns to normal."),
        EngineStatus::On => line("On", Some(Mark::Live), "System audio plays through the spatializer."),
        EngineStatus::Off if s.permission_needed => line("Needs permission", Some(Mark::Warn), "Audio capture isn’t allowed yet."),
        EngineStatus::Off if !s.can_run => line("Driver not installed", Some(Mark::Warn), "The selected capture needs the atmos-control driver."),
        EngineStatus::Off if s.last_error.is_some() => line("Couldn’t start", Some(Mark::Error), "The last start failed; see below."),
        EngineStatus::Off => line("Off", Some(Mark::Idle), "System audio plays normally."),
    }
}

fn output_line(s: &Snapshot) -> Line {
    let name = if s.output_name.trim().is_empty() { "—".to_owned() } else { s.output_name.clone() };
    let help = match s.capture_mode {
        CaptureMode::Tap => format!("{name}: follows the macOS sound output."),
        CaptureMode::Loopback => format!("{name}, through the atmos-control virtual device."),
    };
    line(name, None, help)
}

fn hrtf_line(s: &Snapshot) -> Line {
    let h = &s.hrtf;
    let (value, mark) = match h.state {
        HrtfState::Personalized => ("Personalized", Mark::Live),
        HrtfState::Generic => ("Generic", Mark::Idle),
        HrtfState::Inactive => ("Inactive", Mark::Idle),
    };
    let value = if h.short.is_empty() { value.to_owned() } else { h.short.clone() };
    let caption = (h.state == HrtfState::Generic && !h.detail.is_empty()).then(|| h.detail.clone());
    Line { value, mark: Some(mark), help: h.detail.clone(), caption }
}

fn head_line(s: &Snapshot) -> Line {
    let h = &s.head_track;
    let (fallback, mark, help) = match h.state {
        HeadTrackState::Tracking => ("Tracking", Mark::Live, "Following your head with motion data from the headphones."),
        HeadTrackState::Unavailable => ("Unavailable", Mark::Idle, "No head-motion data: needs AirPods (or headphones that report head motion) as the output."),
        HeadTrackState::Inactive => ("Inactive", Mark::Idle, "Starts with the engine."),
        HeadTrackState::Off => ("Off", Mark::Idle, "Turned off below."),
    };
    let value = if h.text.is_empty() { fallback.to_owned() } else { h.text.clone() };
    line(value, Some(mark), help)
}

/// What a start in flight is waiting on, when the engine says more than "Starting…".
fn waiting_detail(s: &Snapshot) -> Option<String> {
    let text = s.engine_status_text.trim();
    (s.engine_status == EngineStatus::Starting && s.busy && !text.is_empty() && text != "Starting…").then(|| text.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use atmos_core::{Engine, MockPreset};

    fn model(preset: MockPreset) -> Model {
        let e = Engine::mock(preset);
        let s = e.snapshot();
        Model::new(&s)
    }

    #[test]
    fn playing_reads_live_everywhere_with_no_notices() {
        let m = model(MockPreset::Playing);
        assert_eq!((m.engine.value.as_str(), m.engine.mark), ("On", Some(Mark::Live)));
        assert_eq!(m.output.value, "AirPods Pro");
        assert_eq!((m.hrtf.value.as_str(), m.hrtf.mark, m.hrtf.caption.as_deref()), ("Personalized", Some(Mark::Live), None));
        assert!(m.notices.is_empty());
    }

    #[test]
    fn generic_hrtf_says_why() {
        let m = model(MockPreset::Speakers);
        assert_eq!(m.hrtf.value, "Generic");
        assert_eq!(m.hrtf.caption.as_deref(), Some("Applies to headphones only."));
        assert_eq!(m.head.value, "Unavailable");
    }

    #[test]
    fn a_start_held_by_the_consent_prompt_explains_itself() {
        let plain = model(MockPreset::Starting);
        assert_eq!((plain.engine.value.as_str(), plain.engine.mark), ("Starting…", Some(Mark::Busy)));
        assert!(plain.notices.is_empty());
        let waiting = model(MockPreset::AwaitingConsent);
        assert_eq!(waiting.engine.mark, Some(Mark::Busy));
        assert_eq!(waiting.notices.len(), 1);
        assert_eq!(waiting.notices[0].title, "Awaiting capture permission…");
        assert_eq!(waiting.notices[0].actions, vec![Action::OpenPrivacy]);
    }

    #[test]
    fn problems_offer_their_recovery() {
        let p = model(MockPreset::PermissionNeeded);
        assert_eq!(p.engine.mark, Some(Mark::Warn));
        assert_eq!(p.notices[0].actions, vec![Action::OpenPrivacy, Action::RetryCapture]);
        let e = model(MockPreset::Error);
        assert_eq!((e.engine.value.as_str(), e.engine.mark), ("Couldn’t start", Some(Mark::Error)));
        assert_eq!(e.notices[0].kind, NoticeKind::Failed);
        assert_eq!(e.notices[0].actions, vec![Action::StartAgain]);
    }

    #[test]
    fn the_surround_advisory_is_information() {
        let m = model(MockPreset::Surround);
        assert!(m.advisory.is_some());
        assert!(m.notices.is_empty());
        assert_eq!(m.hrtf.caption.as_deref(), Some("Unavailable with the virtual device."));
    }
}
