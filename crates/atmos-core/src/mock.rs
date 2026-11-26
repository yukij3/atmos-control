//! A stand-in engine with the real one's state model, for headless renders, screenshots and
//! view work without touching system audio. Commands behave like the real engine's (power has
//! a short Starting…/Stopping… phase, rebuilds set `busy`, the statuses derive the same way);
//! telemetry is a deterministic function of the clock passed to [`MockEngine::tick`], so a
//! headless frame at a given virtual time always renders the same.

use crate::types::*;

/// A starting point for the mock (env `ATMOS_MOCK=<name>`, or a Rune scene).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum MockPreset {
    /// On, AirPods Pro, personalized HRTF engaged, head tracking live, music playing.
    #[default]
    Playing,
    /// Off, AirPods Pro the system output.
    Off,
    /// Power just switched on, the engine still starting.
    Starting,
    /// The tap start failed on audio-capture consent.
    PermissionNeeded,
    /// Off after a failed start.
    Error,
    /// On, built-in speakers: generic HRTF, no head-motion data.
    Speakers,
    /// On, loopback 7.1.4 with the 12-channel driver: 12 channel meters, generic HRTF.
    Surround,
}

impl MockPreset {
    pub const ALL: &'static [MockPreset] = &[
        MockPreset::Playing, MockPreset::Off, MockPreset::Starting, MockPreset::PermissionNeeded,
        MockPreset::Error, MockPreset::Speakers, MockPreset::Surround,
    ];

    pub fn name(self) -> &'static str {
        match self {
            MockPreset::Playing => "playing",
            MockPreset::Off => "off",
            MockPreset::Starting => "starting",
            MockPreset::PermissionNeeded => "permission",
            MockPreset::Error => "error",
            MockPreset::Speakers => "speakers",
            MockPreset::Surround => "surround",
        }
    }

    pub fn from_name(name: &str) -> Option<MockPreset> {
        MockPreset::ALL.iter().copied().find(|p| p.name() == name)
    }
}

const AIRPODS: u32 = 101;
const SPEAKERS: u32 = 102;
const DISPLAY: u32 = 103;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Pending {
    /// The start lands at this time: on, or a permission failure.
    Start { at: f64, grant: bool },
    Stop { at: f64 },
    Rebuild { at: f64 },
}

pub struct MockEngine {
    s: Snapshot,
    defaults: Config,
    /// The macOS default output (what Personalized follows).
    system_output: u32,
    /// The consent prompt was answered: starts succeed.
    granted: bool,
    pending: Option<Pending>,
    now: f64,
    visible: (bool, bool),
}

impl MockEngine {
    pub fn new(preset: MockPreset) -> MockEngine {
        let mut m = MockEngine {
            s: Snapshot::default(),
            defaults: Config::DEFAULT,
            system_output: AIRPODS,
            granted: true,
            pending: None,
            now: 0.0,
            visible: (false, false),
        };
        m.apply_preset(preset);
        m
    }

    /// Reset to a preset (keeps the clock and visibility).
    pub fn apply_preset(&mut self, preset: MockPreset) {
        let generation = self.s.generation;
        self.s = Snapshot {
            outputs: vec![
                OutputDevice { id: AIRPODS, name: "AirPods Pro".into(), is_airpods: true },
                OutputDevice { id: SPEAKERS, name: "MacBook Pro Speakers".into(), is_airpods: false },
                OutputDevice { id: DISPLAY, name: "Studio Display Speakers".into(), is_airpods: false },
            ],
            config: self.defaults,
            ..Snapshot::default()
        };
        self.s.generation = generation;
        self.system_output = AIRPODS;
        self.granted = true;
        self.pending = None;
        match preset {
            MockPreset::Playing => self.s.is_on = true,
            MockPreset::Off => {}
            MockPreset::Starting => {
                self.s.busy = true;
                self.pending = Some(Pending::Start { at: f64::INFINITY, grant: true });
            }
            MockPreset::PermissionNeeded => {
                self.s.permission_needed = true;
                self.granted = false;
            }
            MockPreset::Error => {
                self.s.last_error = Some("Personalized capture unavailable: audio setup failed: AudioDeviceStart (-10875).".into());
            }
            MockPreset::Speakers => {
                self.s.is_on = true;
                self.system_output = SPEAKERS;
                self.s.config.output_type = OutputType::BuiltInSpeakers;
            }
            MockPreset::Surround => {
                self.s.is_on = true;
                self.s.atmos_present = true;
                self.s.surround_driver_installed = true;
                self.s.capture_choice = CaptureChoice::Surround;
                self.s.config.source_mode = SourceMode::Surround714;
            }
        }
        self.derive();
        self.changed();
    }

    pub fn snapshot(&self) -> &Snapshot { &self.s }
    pub fn generation(&self) -> u64 { self.s.generation }
    pub fn defaults(&self) -> Config { self.defaults }

    fn changed(&mut self) { self.s.generation = self.s.generation.wrapping_add(1); }

    fn device(&self, id: u32) -> Option<&OutputDevice> { self.s.outputs.iter().find(|d| d.id == id) }

    /// The device audio renders to: the picked sink in the loopback modes, else the macOS
    /// default output.
    fn render_device(&self) -> u32 {
        match (self.s.capture_choice, self.s.selected_output) {
            (CaptureChoice::Personalized, _) | (_, None) => self.system_output,
            (_, Some(id)) => id,
        }
    }

    fn any_visible(&self) -> bool { self.visible.0 || self.visible.1 }

    /// Mirror of EngineController's derived state.
    fn derive(&mut self) {
        let s = &mut self.s;
        s.capture_mode = if s.capture_choice == CaptureChoice::Personalized { CaptureMode::Tap } else { CaptureMode::Loopback };
        s.can_run = s.capture_choice.available(s.atmos_present, s.surround_driver_installed);
        s.engine_status = if s.busy && !s.is_on && matches!(self.pending, Some(Pending::Stop { .. })) {
            EngineStatus::Stopping
        } else if s.busy && !s.is_on {
            EngineStatus::Starting
        } else if s.is_on {
            EngineStatus::On
        } else {
            EngineStatus::Off
        };
        s.engine_status_text = match s.engine_status {
            EngineStatus::Off => "Off",
            EngineStatus::Starting => "Starting…",
            EngineStatus::On => "On",
            EngineStatus::Stopping => "Stopping…",
        }.into();
        let render = self.render_device();
        let dev = self.s.outputs.iter().find(|d| d.id == render).cloned();
        let s = &mut self.s;
        s.output_name = dev.as_ref().map_or_else(|| "—".into(), |d| d.name.clone());
        let airpods = dev.as_ref().is_some_and(|d| d.is_airpods);

        s.personalization_disabled_reason = if s.capture_mode == CaptureMode::Loopback {
            Some("Unavailable with the virtual device.".into())
        } else if s.config.output_type != OutputType::Headphones {
            Some("Applies to headphones only.".into())
        } else if s.config.algorithm != Algorithm::Automatic {
            Some("Needs the Automatic algorithm.".into())
        } else {
            None
        };
        let engaged = s.is_on && s.personalization_disabled_reason.is_none()
            && s.config.hrtf_mode != HrtfMode::Off && airpods;
        s.telemetry.personalized_hrtf_engaged = engaged;
        s.hrtf = if !s.is_on {
            HrtfStatus { state: HrtfState::Inactive, short: "Inactive".into(), detail: "The engine is off.".into(), engaged: false }
        } else if engaged {
            HrtfStatus { state: HrtfState::Personalized, short: "Personalized".into(), detail: "Your Apple personalized profile is active.".into(), engaged: true }
        } else {
            let detail = s.personalization_disabled_reason.clone().unwrap_or_else(|| {
                if s.config.hrtf_mode == HrtfMode::Off { "Personalized HRTF is turned off.".into() }
                else { "Needs AirPods with a personalized Spatial Audio profile as the system output.".into() }
            });
            HrtfStatus { state: HrtfState::Generic, short: "Generic".into(), detail, engaged: false }
        };

        // Head pose arrives only from AirPods, and (as in the app) only while a surface shows;
        // the last pose is kept while hidden.
        if !s.is_on || !s.config.head_tracking || !airpods {
            s.telemetry.head_pose_live = false;
            s.telemetry.head_yaw = 0.0;
        }
        let state = if !s.config.head_tracking {
            HeadTrackState::Off
        } else if !s.is_on {
            HeadTrackState::Inactive
        } else if s.telemetry.head_pose_live {
            HeadTrackState::Tracking
        } else {
            HeadTrackState::Unavailable
        };
        let text = match state {
            HeadTrackState::Off => "Off",
            HeadTrackState::Inactive => "Inactive",
            HeadTrackState::Tracking => "Tracking",
            HeadTrackState::Unavailable => "Unavailable",
        };
        s.head_track = HeadTrackStatus { state, text: text.into(), active: state == HeadTrackState::Tracking };
        s.music_atmos_advisory = (s.is_on && s.capture_choice == CaptureChoice::Surround)
            .then(|| "For true multichannel, set Music ▸ Settings ▸ Playback ▸ Dolby Atmos to Automatic.".into());
        s.soundstage_is_default = s.config.soundstage_is_default(&self.defaults);
        s.rendering_is_default = s.config.rendering_is_default(&self.defaults);
        if !s.is_on {
            s.telemetry = Telemetry::default();
        }
    }

    // ── Clock ────────────────────────────────────────────────────────────────────────────

    /// Advance the mock to `now` seconds: land due transitions and, while on and a surface is
    /// visible, move the meters and the head pose. Returns whether the snapshot changed.
    pub fn tick(&mut self, now: f64) -> bool {
        self.now = now;
        let mut changed = false;
        if let Some(p) = self.pending {
            match p {
                Pending::Start { at, grant } if now >= at => {
                    self.pending = None;
                    self.s.busy = false;
                    if grant {
                        self.s.is_on = true;
                    } else {
                        self.s.permission_needed = true;
                    }
                    changed = true;
                }
                Pending::Stop { at } if now >= at => {
                    self.pending = None;
                    self.s.busy = false;
                    self.s.is_on = false;
                    changed = true;
                }
                Pending::Rebuild { at } if now >= at => {
                    self.pending = None;
                    self.s.busy = false;
                    changed = true;
                }
                _ => {}
            }
        }
        if self.s.is_on && self.any_visible() {
            self.animate(now);
            changed = true;
        }
        if changed {
            self.derive();
            self.changed();
        }
        changed
    }

    /// Whether the app should keep calling [`tick`](Self::tick) (~30 Hz): something is in
    /// flight, or live readouts are on screen.
    pub fn wants_ticks(&self) -> bool {
        self.pending.is_some_and(|p| match p {
            Pending::Start { at, .. } | Pending::Stop { at } | Pending::Rebuild { at } => at.is_finite(),
        }) || (self.s.is_on && self.any_visible())
    }

    fn animate(&mut self, t: f64) {
        let level = |phase: f64| -> f32 {
            let v = 0.42 + 0.22 * (2.1 * t + phase).sin() + 0.12 * (7.3 * t + 2.0 * phase).sin()
                + 0.06 * (13.7 * t + phase).sin();
            v.clamp(0.0, 0.97) as f32
        };
        let tel = &mut self.s.telemetry;
        tel.meter_l = level(0.0);
        tel.meter_r = level(1.3);
        tel.peak_hold_l = (0.80 + 0.12 * (0.45 * t).sin()).max(tel.meter_l as f64) as f32;
        tel.peak_hold_r = (0.78 + 0.12 * (0.45 * t + 0.9).sin()).max(tel.meter_r as f64) as f32;
        tel.channel_peaks = if self.s.config.source_mode.is_surround() {
            (0..12).map(|i| if i == 3 { level(5.0) * 0.6 } else { level(i as f64 * 0.7) * if i >= 8 { 0.55 } else { 1.0 } }).collect()
        } else {
            Vec::new()
        };
        let airpods = self.device(self.render_device()).is_some_and(|d| d.is_airpods);
        let tel = &mut self.s.telemetry;
        if self.s.config.head_tracking && airpods {
            tel.head_pose_live = true;
            tel.head_yaw = 0.55 * (0.7 * t).sin() + 0.1 * (2.3 * t).sin();
        }
        tel.total_captured = (t * 48_000.0) as u64;
        tel.total_played = tel.total_captured.saturating_sub(512);
        tel.ring_fill = 512 + ((t * 31.0).sin() * 64.0) as i64 as u64;
    }

    // ── Commands (same contracts as the C ABI's) ────────────────────────────────────────

    pub fn set_visible(&mut self, panel: bool, settings: bool) {
        self.visible = (panel, settings);
    }

    pub fn power_on(&mut self) {
        if self.s.busy || self.s.is_on { return; }
        self.s.permission_needed = false;
        self.s.last_error = None;
        if !self.s.can_run {
            return;
        }
        self.s.busy = true;
        self.pending = Some(Pending::Start { at: self.now + 0.6, grant: self.granted });
        self.derive();
        self.changed();
    }

    pub fn power_off(&mut self) {
        if !self.s.is_on && !self.s.busy { return; }
        self.s.is_on = false;
        self.s.busy = true;
        self.pending = Some(Pending::Stop { at: self.now + 0.3 });
        self.derive();
        self.changed();
    }

    pub fn toggle(&mut self) {
        if self.s.is_on { self.power_off() } else { self.power_on() }
    }

    /// The mock answers the consent prompt with "allow" on retry.
    pub fn retry_capture(&mut self) {
        self.granted = true;
        self.s.permission_needed = false;
        self.power_on();
    }

    pub fn set_capture_choice(&mut self, choice: CaptureChoice) {
        if self.s.busy || choice == self.s.capture_choice { return; }
        self.s.permission_needed = false;
        self.s.last_error = None;
        self.s.capture_choice = choice;
        match choice {
            CaptureChoice::Surround => self.s.config.source_mode = SourceMode::Surround714,
            _ if self.s.config.source_mode.is_surround() => self.s.config.source_mode = SourceMode::DualPointStereo,
            _ => {}
        }
        if self.s.is_on { self.rebuild(); }
        self.derive();
        self.changed();
    }

    pub fn select_output(&mut self, selection: OutputSelection) {
        if self.s.capture_choice == CaptureChoice::Personalized { return; }
        self.s.selected_output = match selection {
            OutputSelection::FollowDefault => None,
            OutputSelection::Device(id) if self.device(id).is_some() => Some(id),
            OutputSelection::Device(_) => return,
        };
        if self.s.is_on && !self.s.busy { self.rebuild(); }
        self.derive();
        self.changed();
    }

    pub fn set_field(&mut self, field: ConfigField) {
        let before = self.s.config;
        field.apply(&mut self.s.config);
        if self.s.config != before {
            self.derive();
            self.changed();
        }
    }

    pub fn apply_config(&mut self) {
        let c = &mut self.s.config;
        if self.s.capture_choice == CaptureChoice::Personalized && c.source_mode.is_surround() {
            c.source_mode = SourceMode::DualPointStereo;
        }
        c.distance = c.distance.clamp(0.35, c.distance_max.max(0.35));
        if self.s.is_on && !self.s.busy { self.rebuild(); }
        self.derive();
        self.changed();
    }

    fn rebuild(&mut self) {
        self.s.busy = true;
        self.pending = Some(Pending::Rebuild { at: self.now + 0.25 });
    }

    pub fn set_source(&mut self, u: SourceUpdate) {
        let c = &mut self.s.config;
        if let Some(v) = u.azimuth { c.azimuth = v; }
        if let Some(v) = u.elevation { c.elevation = v; }
        if let Some(v) = u.distance { c.distance = v.clamp(0.35, c.distance_max.max(0.35)); }
        if let Some(v) = u.gain { c.gain = v; }
        if let Some(v) = u.stereo_width { c.stereo_width = v; }
        self.derive();
        self.changed();
    }

    pub fn set_reverb_blend(&mut self, percent: f32) {
        self.s.config.reverb_blend = percent;
        self.derive();
        self.changed();
    }

    pub fn reset_soundstage(&mut self) {
        let d = self.defaults;
        self.set_source(SourceUpdate {
            azimuth: Some(d.azimuth), elevation: Some(d.elevation), distance: Some(d.distance),
            gain: Some(d.gain), stereo_width: Some(d.stereo_width),
        });
    }

    pub fn reset_rendering(&mut self) {
        let d = self.defaults;
        let c = &mut self.s.config;
        c.algorithm = d.algorithm;
        c.interaural_delay = d.interaural_delay;
        c.distance_attenuation = d.distance_attenuation;
        c.attenuation_curve = d.attenuation_curve;
        c.distance_ref = d.distance_ref;
        c.distance_max = d.distance_max;
        c.distance_max_atten = d.distance_max_atten;
        c.reverb_enabled = d.reverb_enabled;
        c.reverb_room = d.reverb_room;
        c.reverb_blend = d.reverb_blend;
        c.global_reverb_gain = d.global_reverb_gain;
        self.apply_config();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn playing_preset_is_on_personalized_and_tracking_once_visible() {
        let mut m = MockEngine::new(MockPreset::Playing);
        assert!(m.snapshot().is_on);
        assert_eq!(m.snapshot().hrtf.state, HrtfState::Personalized);
        // Hidden: no motion data yet.
        assert_eq!(m.snapshot().head_track.state, HeadTrackState::Unavailable);
        m.set_visible(true, false);
        assert!(m.tick(1.0));
        let s = m.snapshot();
        assert_eq!(s.head_track.state, HeadTrackState::Tracking);
        assert!(s.telemetry.meter_l > 0.0 && s.telemetry.meter_r > 0.0);
        assert!(m.wants_ticks());
    }

    #[test]
    fn power_cycles_through_starting_and_stopping() {
        let mut m = MockEngine::new(MockPreset::Off);
        m.tick(0.0);
        m.power_on();
        assert_eq!(m.snapshot().engine_status, EngineStatus::Starting);
        assert!(m.snapshot().busy);
        m.tick(1.0);
        assert_eq!(m.snapshot().engine_status, EngineStatus::On);
        m.power_off();
        assert_eq!(m.snapshot().engine_status, EngineStatus::Stopping);
        m.tick(2.0);
        assert_eq!(m.snapshot().engine_status, EngineStatus::Off);
        assert!(!m.wants_ticks());
    }

    #[test]
    fn permission_then_retry_starts() {
        let mut m = MockEngine::new(MockPreset::PermissionNeeded);
        m.power_on();
        m.tick(1.0);
        assert!(m.snapshot().permission_needed && !m.snapshot().is_on);
        m.retry_capture();
        m.tick(2.0);
        assert!(m.snapshot().is_on && !m.snapshot().permission_needed);
    }

    #[test]
    fn speakers_are_generic_with_a_reason() {
        let m = MockEngine::new(MockPreset::Speakers);
        let s = m.snapshot();
        assert_eq!(s.hrtf.state, HrtfState::Generic);
        assert_eq!(s.personalization_disabled_reason.as_deref(), Some("Applies to headphones only."));
        assert_eq!(s.output_name, "MacBook Pro Speakers");
    }

    #[test]
    fn distance_is_clamped_to_max_like_the_engine() {
        let mut m = MockEngine::new(MockPreset::Off);
        m.set_field(ConfigField::DistanceMax(2.0));
        m.apply_config();
        m.set_source(SourceUpdate { distance: Some(5.0), ..Default::default() });
        assert_eq!(m.snapshot().config.distance, 2.0);
        assert!(!m.snapshot().soundstage_is_default);
        m.reset_rendering();
        m.reset_soundstage();
        assert!(m.snapshot().soundstage_is_default && m.snapshot().rendering_is_default);
    }
}
