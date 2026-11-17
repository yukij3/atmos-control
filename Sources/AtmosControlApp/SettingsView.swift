// SettingsView — the full control surface, reorganized to the DESIGN.md-locked IA:
// Output · Soundstage · Personalization · Rendering (Advanced) · Levels. Native grouped
// Form (System-Settings idiom); SF-Mono readouts; one accent; every control has units,
// a truthful disabled reason, and a reset.

import SwiftUI
import CoreAudio
import SpatialEngine

struct SettingsView: View {
    @Environment(EngineController.self) private var controller

    /// Dev-only diagnostics (SPSC ring fill, captured/played) are hidden from the product
    /// surface (F6) and only appear when ATMOS_DEBUG is set.
    private var showDebug: Bool { ProcessInfo.processInfo.environment["ATMOS_DEBUG"] != nil }

    /// Drives the Rendering ▸ Advanced disclosure so the WHOLE label row (not just the
    /// chevron) toggles it — see the custom label below.
    @State private var advancedExpanded = false

    var body: some View {
        Form {
            output
            soundstage
            personalization
            rendering
            levels
        }
        .formStyle(.grouped)
        .disabled(controller.isStarting)
        .tint(.instrument)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 460, idealHeight: 640)
        .onAppear { controller.refreshDevices(); controller.settingsAppeared() }
        .onDisappear { controller.settingsDisappeared() }
    }

    // MARK: 1. Output

    private var output: some View {
        Section {
            Picker("Audio capture", selection: captureChoiceBinding) {
                ForEach(CaptureChoice.allCases) { Text($0.label).tag($0) }
            }
            if controller.captureChoice == .surround && !controller.surroundDriverInstalled {
                notice("Surround 7.1.4 requires the 12-channel atmos-control driver — install it to enable this mode.")
            } else if !controller.surroundDriverInstalled {
                Text("Surround 7.1.4 requires the 12-channel atmos-control driver (not installed).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if controller.captureChoice != .personalized && !controller.atmosPresent {
                notice("Virtual device not installed — use Personalized capture (no driver needed) or install the driver.")
                Button("Use Personalized capture") { controller.setCaptureChoice(.personalized) }
            }

            Picker("Output device", selection: outputBinding) {
                Text("Follow system default").tag(AudioDeviceID?.none)
                ForEach(controller.outputs) { d in
                    Text(d.name).tag(AudioDeviceID?.some(d.id))
                }
            }
            Picker("Output type", selection: rebuild(\.outputType)) {
                ForEach(OutputType.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Signal path") {
                Text(controller.isOn ? "system → capture → \(controller.outputName)" : "idle")
                    .foregroundStyle(.secondary).font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            if let hint = controller.musicAtmosAdvisory {
                Label(hint, systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Output")
        } footer: {
            Text(controller.captureChoice.subtitle)
        }
    }

    // MARK: 2. Soundstage

    private var soundstage: some View {
        Section {
            HStack { Spacer(); VisualizerView(); Spacer() }
                .padding(.vertical, 4)

            Picker("Source mode", selection: rebuild(\.sourceMode)) {
                ForEach(SourceRenderMode.allCases) { Text($0.label).tag($0) }
            }
            Text(sourceModeExplainer)
                .font(.footnote).foregroundStyle(.secondary)

            liveSlider("Azimuth",   Param.azimuth,   value: controller.config.azimuth)   { controller.setSource(azimuth: $0) }
            liveSlider("Elevation", Param.elevation, value: controller.config.elevation) { controller.setSource(elevation: $0) }
            liveSlider("Distance",  Param.distance,  value: controller.config.distance)  { controller.setSource(distance: $0) }
            liveSlider("Gain",      Param.gain,      value: controller.config.gain)      { controller.setSource(gain: $0) }
            if controller.config.sourceMode == .dualPointStereo {
                liveSlider("Stereo width", Param.width, value: controller.config.stereoWidth) { controller.setSource(width: $0) }
            }
            Button("Reset soundstage") { controller.resetSoundstage() }
                .disabled(!controller.config.spatialize)
        } header: {
            Text("Soundstage")
        } footer: {
            Text("Drag the source dot on the radar, or use the sliders. Double-click a readout to reset that value.")
        }
        .disabled(!controller.config.spatialize)
    }

    private var sourceModeExplainer: String {
        switch controller.config.sourceMode {
        case .dualPointStereo:   return "Stereo Points — L and R rendered as two virtual speakers at ±width."
        case .ambienceBedStereo: return "Stereo Bed — full stereo image placed as an ambience bed."
        case .pointSourceMono:   return "Mono Point — summed to a single point source."
        case .surround714:       return "Surround 7.1.4 — twelve channels placed at their canonical speaker angles."
        case .surroundBed714:    return "Surround Bed 7.1.4 — the full 7.1.4 field placed as an ambience bed."
        }
    }

    // MARK: 3. Personalization

    private var personalization: some View {
        Section {
            Toggle("Head tracking", isOn: rebuild(\.headTracking))
                .disabled(!controller.config.spatialize)

            Picker("Personalized HRTF", selection: rebuild(\.hrtfMode)) {
                ForEach(HRTFMode.allCases) { Text($0 == .auto ? "Automatic" : $0.label).tag($0) }
            }
            .disabled(!controller.config.spatialize || controller.personalizationDisabledReason != nil)
            if let reason = controller.personalizationDisabledReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }

            LabeledContent("Status (3116)") {
                Text(controller.hrtfStatus.long)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(controller.hrtfStatus.engaged ? Color.instrument : .secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Personalization")
        } footer: {
            Text("Control Center ▸ Sound ▸ AirPods ▸ Spatial Audio should be OFF while atmos-control runs — otherwise audio is spatialized twice.")
        }
    }

    // MARK: 4. Rendering (Advanced)

    private var rendering: some View {
        Section("Rendering") {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                Picker("Algorithm", selection: rebuild(\.algorithm)) {
                    ForEach(SpatAlgorithm.allCases) {
                        Text($0 == .useOutputType ? "Automatic (from output type)" : $0.label).tag($0)
                    }
                }
                if controller.config.algorithm != .useOutputType {
                    Label("Personalized HRTF is unavailable with this algorithm.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }

                Toggle("Inter-aural delay", isOn: rebuild(\.interauralDelay))
                Toggle("Distance attenuation", isOn: rebuild(\.distanceAttenuation))
                Picker("Attenuation curve", selection: rebuild(\.attenuationCurve)) {
                    ForEach(AttenuationCurve.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!controller.config.distanceAttenuation)

                rebuildSlider("Reference distance", Param.distanceRef, \.distanceRef)
                    .disabled(!controller.config.distanceAttenuation)
                rebuildSlider("Max distance", Param.distanceMax, \.distanceMax)
                    .disabled(!controller.config.distanceAttenuation)
                rebuildSlider("Max attenuation", Param.distanceAtten, \.distanceMaxAtten)
                    .disabled(!controller.config.distanceAttenuation)

                Divider()

                Toggle("Room reverb", isOn: rebuild(\.reverbEnabled))
                Picker("Room size", selection: rebuild(\.reverbRoomType)) {
                    ForEach(ReverbRoomType.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!controller.config.reverbEnabled)
                reverbBlendSlider
                    .disabled(!controller.config.reverbEnabled)
                Text("Reverb is audible under the HRTF / HRTF-HQ algorithms only; it is inert under Automatic.")
                    .font(.footnote).foregroundStyle(.secondary)

                Button("Reset rendering") { controller.resetRendering() }
            } label: {
                // Make the ENTIRE row toggle the disclosure, not just the native chevron.
                // The chevron (and its rotation animation) stays, driven by advancedExpanded.
                Text("Advanced")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { advancedExpanded.toggle() } }
            }
            .disabled(!controller.config.spatialize)
        }
    }

    // MARK: 5. Levels

    private var levels: some View {
        Section("Levels") {
            HStack { Spacer(); MeterView().frame(width: 90, height: 150); Spacer() }
            LabeledContent("Peak L / R") {
                Text(peakText).font(.system(.callout, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(controller.isOn ? Color.primary : .secondary)
            }
            LabeledContent("Engine") {
                Text(controller.isOn ? "Running" : "Stopped")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(controller.isOn ? Color.instrument : .secondary)
            }
            if controller.channelPeaks.count > 2 {
                SurroundMeterRow(peaks: controller.channelPeaks)
            }
            if showDebug {
                LabeledContent("Ring fill") {
                    Text("\(controller.ringFill) frames").font(.system(.callout, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Captured / Played") {
                    Text("\(controller.totalCaptured) / \(controller.totalPlayed)")
                        .font(.system(.callout, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var peakText: String {
        guard controller.isOn else { return "—" }
        func db(_ x: Float) -> String { x > 0.0001 ? String(format: "%+.0f", linearToDb(x)) : "−∞" }
        return "\(db(controller.meterL)) / \(db(controller.meterR)) dB"
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Bindings

    /// Rebuild-class config change (output type, HRTF, algorithm, source mode, flags, reverb).
    private func rebuild<T>(_ kp: WritableKeyPath<SpatialConfig, T>) -> Binding<T> {
        Binding(get: { controller.config[keyPath: kp] },
                set: { controller.config[keyPath: kp] = $0; controller.applyConfig() })
    }

    private var outputBinding: Binding<AudioDeviceID?> {
        Binding(get: { controller.selectedOutputID },
                set: { id in controller.selectOutput(controller.outputs.first(where: { $0.id == id })) })
    }

    private var captureChoiceBinding: Binding<CaptureChoice> {
        Binding(get: { controller.captureChoice },
                set: { choice in
                    // Guard the surround option when the 12-channel driver isn't installed.
                    if choice == .surround && !controller.surroundDriverInstalled { return }
                    controller.setCaptureChoice(choice)
                })
    }

    // MARK: Slider builders

    /// Live source param (no rebuild). Readout doubles as a double-click-to-default target.
    @ViewBuilder
    private func liveSlider(_ label: String, _ spec: ParamSpec, value: Float,
                            live: @escaping (Float) -> Void) -> some View {
        let binding = Binding<Double>(get: { Double(value) }, set: { live(Float($0)) })
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: binding, in: spec.range)
                Text(spec.text(value))
                    .font(.system(.callout, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { live(Float(spec.def)) }
                    .help("Double-click to reset to default (\(spec.text(spec.def)))")
            }
        }
    }

    /// Rebuild-class Float param: mutate config live for the readout, rebuild only when the
    /// drag ends (so a slider drag doesn't storm the graph with rebuilds).
    @ViewBuilder
    private func rebuildSlider(_ label: String, _ spec: ParamSpec, _ kp: WritableKeyPath<SpatialConfig, Float>) -> some View {
        let value = controller.config[keyPath: kp]
        let binding = Binding<Double>(get: { Double(value) },
                                      set: { controller.config[keyPath: kp] = Float($0) })
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: binding, in: spec.range) { editing in
                    if !editing { controller.applyConfig() }
                }
                Text(spec.text(value))
                    .font(.system(.callout, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { controller.config[keyPath: kp] = Float(spec.def); controller.applyConfig() }
                    .help("Double-click to reset to default (\(spec.text(spec.def)))")
            }
        }
    }

    /// Reverb blend is a live parameter (AudioUnitSetParameter), no rebuild.
    @ViewBuilder
    private var reverbBlendSlider: some View {
        let spec = Param.reverbBlend
        let value = controller.config.reverbBlend
        let binding = Binding<Double>(get: { Double(value) }, set: { controller.setReverbBlend(Float($0)) })
        LabeledContent("Reverb blend") {
            HStack(spacing: 10) {
                Slider(value: binding, in: spec.range)
                Text(spec.text(value))
                    .font(.system(.callout, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { controller.setReverbBlend(Float(spec.def)) }
                    .help("Double-click to reset to default (\(spec.text(spec.def)))")
            }
        }
    }
}

// MARK: - Surround (7.1.4) per-channel meter row

/// A compact 12-channel meter for surround capture (amendment H). SF-Mono channel labels in
/// Atmos_7_1_4 order; slim vertical bars from the per-channel linear peaks.
struct SurroundMeterRow: View {
    let peaks: [Float]
    private static let labels = ["L", "R", "C", "LFE", "Ls", "Rs", "Rls", "Rrs", "Vhl", "Vhr", "Ltr", "Rtr"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Channels (7.1.4)").font(.footnote).foregroundStyle(.secondary)
            Canvas { ctx, size in
                let n = min(peaks.count, Self.labels.count)
                guard n > 0 else { return }
                let labelH: CGFloat = 12
                let top: CGFloat = 2, bot = size.height - labelH
                let H = bot - top
                let slot = size.width / CGFloat(n)
                let barW = min(slot - 4, 12)
                let grid = Color.secondary
                for i in 0..<n {
                    let cx = slot * CGFloat(i) + slot / 2
                    let bx = cx - barW / 2
                    ctx.stroke(Path(roundedRect: CGRect(x: bx, y: top, width: barW, height: H), cornerRadius: 2),
                               with: .color(grid.opacity(0.35)), lineWidth: 1)
                    // linear peak → -60…0 dB fill height
                    let p = peaks[i]
                    let db = p > 0 ? 20 * log10(p) : -60
                    let f = CGFloat((max(-60, min(0, db)) + 60) / 60)
                    let fillH = H * f
                    let col: Color = db >= -1 ? .red : (db >= -6 ? .orange : .instrument)
                    if fillH > 0.5 {
                        ctx.fill(Path(CGRect(x: bx + 1, y: bot - fillH, width: barW - 2, height: fillH)), with: .color(col))
                    }
                    ctx.draw(Text(Self.labels[i]).font(.system(size: 7, design: .monospaced)).foregroundColor(grid),
                             at: CGPoint(x: cx, y: bot + labelH / 2 + 1), anchor: .center)
                }
            }
            .frame(height: 78)
            .accessibilityLabel("Surround channel levels")
        }
    }
}
