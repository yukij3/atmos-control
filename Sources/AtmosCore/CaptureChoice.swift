// CaptureChoice — the three capture options the user chooses between (amendment D). Two of
// them share the loopback engine path but differ in channel width; the engine still speaks in
// `CaptureMode` (+ `SourceRenderMode`), which `EngineController` derives from this.
//
// Raw values are the C ABI's (ATMOS_CAPTURE_*). Labels, subtitles and the parameter ranges
// and readout formats are presentation and live in the Rust UI (crates/atmos-core); the
// parameter defaults come from `SpatialConfig()` (EngineController.defaults).

enum CaptureChoice: UInt32, CaseIterable {
    case personalized = 0    // process tap; AirPods stay default → personalized HRTF can engage
    case surround = 1        // loopback, 7.1.4 — true multichannel, personalized profile unavailable
    case virtualStereo = 2   // loopback, stereo — works with any output, generic binaural
}
