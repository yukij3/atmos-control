// atmos-control — SwiftUI menu-bar control app (Phase 3 MVP).
// Apple-native restraint; instrument-grade-but-calm. One accent = instrument cyan.

import SwiftUI
import AppKit

extension Color {
    /// The single accent: engaged/active state, source dot, power-on glow.
    static let instrument = Color(red: 0.34, green: 0.82, blue: 0.86)
}

@main
struct AtmosControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = EngineController()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(controller)
        } label: {
            Image(nsImage: GlyphCache.image(on: controller.isOn))
        }
        .menuBarExtraStyle(.window)

        // Full control surface — opened from the panel's settings button. A normal
        // resizable window (NOT sized to content: a grouped Form in a content-sized
        // window infinite-loops AppKit's constraint pass).
        Window("atmos-control — Settings", id: "settings") {
            SettingsView()
                .environment(controller)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 480, height: 620)
        .defaultPosition(.center)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindows: [NSWindow] = []
    // Lazy: only the dev-only ATMOS_PREVIEW path uses it. Constructing it eagerly spun up a
    // second EngineController at every launch — a duplicate engine + a duplicate pair of
    // system-global CoreAudio property listeners — in the shipping (accessory) app.
    private lazy var previewController = EngineController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mode = ProcessInfo.processInfo.environment["ATMOS_PREVIEW"] ?? ""
        let preview = !mode.isEmpty
        NSApp.setActivationPolicy(preview ? .regular : .accessory)   // accessory = menu-bar agent
        guard preview else { return }

        // Dev-only: ATMOS_PREVIEW=1|panel|settings opens the surface(s) in windows for screenshotting.
        if mode == "1" || mode == "panel" {
            previewWindow(PanelView().environment(previewController), title: "atmos-control", x: 40)
        }
        if mode == "1" || mode == "settings" {
            previewWindow(SettingsView().environment(previewController), title: "Settings", x: 400,
                          fixedSize: NSSize(width: 480, height: 620))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore the system default output + tear down capture on quit / logout / shutdown.
        // Critical in loopback mode: otherwise the default is stranded on the virtual
        // atmos-control sink and all system audio black-holes until manually re-selected.
        // (terminate(_:) invokes this before exit, so the menu's Quit button is covered too.)
        EngineController.shared?.shutdownForTermination()
    }

    private func previewWindow<V: View>(_ root: V, title: String, x: CGFloat, fixedSize: NSSize? = nil) {
        let host = NSHostingController(rootView: root)
        var mask: NSWindow.StyleMask = [.titled, .closable]
        if let s = fixedSize {
            host.preferredContentSize = s   // explicit size: a Form must not drive window size
            mask.insert(.resizable)
        } else {
            host.sizingOptions = [.preferredContentSize]
        }
        let win = NSWindow(contentViewController: host)
        win.title = title
        win.styleMask = mask
        if let s = fixedSize { win.setContentSize(s) }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        win.setFrameTopLeftPoint(NSPoint(x: vf.minX + x, y: vf.maxY - 20))
        win.level = .floating   // sit above other apps for screenshotting
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        previewWindows.append(win)
    }
}

// MARK: - Menu-bar glyph (binaural mark) → rendered to a template NSImage

/// A SwiftUI `Canvas` used directly as a `MenuBarExtra` label renders blank, so we
/// pre-render the glyph to a TEMPLATE NSImage (adapts to light/dark menu bars).
/// Cached: at most one render per state, not one per @Published tick.
@MainActor
enum GlyphCache {
    private static var cache: [Bool: NSImage] = [:]
    static func image(on: Bool) -> NSImage {
        if let img = cache[on] { return img }
        let renderer = ImageRenderer(content: MenuBarGlyph(on: on).frame(width: 18, height: 18))
        renderer.scale = 2
        let img = renderer.nsImage ?? NSImage()
        img.isTemplate = true   // menu bar tints it for the active appearance
        cache[on] = img
        return img
    }
}

struct MenuBarGlyph: View {
    let on: Bool
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 22.0
            let cx = 11 * s, cy = 11 * s
            let col: Color = on ? .instrument : .primary

            func arc(_ r0: CGFloat, _ a0: Double, _ a1: Double) -> Path {
                var p = Path()
                let steps = 30
                let r = r0 * s
                for i in 0...steps {
                    let t = (a0 + (a1 - a0) * Double(i) / Double(steps)) * .pi / 180
                    let pt = CGPoint(x: cx + r * cos(t), y: cy + r * sin(t))   // y-down
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            let lw = (on ? 1.8 : 1.6) * s
            let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
            // right pair (east-facing), left pair (west-facing)
            for (r, a0, a1) in [(7.2, -52.0, 52.0), (4.8, -52.0, 52.0),
                                (7.2, 128.0, 232.0), (4.8, 128.0, 232.0)] {
                ctx.stroke(arc(r, a0, a1), with: .color(col), style: style)
            }
            let hr = (on ? 2.7 : 2.3) * s
            let head = Path(ellipseIn: CGRect(x: cx - hr, y: cy - hr, width: hr * 2, height: hr * 2))
            if on { ctx.fill(head, with: .color(col)) }
            else { ctx.stroke(head, with: .color(col), style: StrokeStyle(lineWidth: lw)) }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(on ? "atmos-control engine on" : "atmos-control engine off")
    }
}
