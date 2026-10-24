import AppKit
import SwiftUI

/// The recording indicator: a small dark capsule at the bottom-center of the screen
/// whose white bars follow the microphone level (PLAN.md §3a).
@Observable
final class FlowPill {
    enum Phase: Equatable {
        case hidden
        case listening(live: Bool)
        case transcribing
        case cancelled
        case failed
    }

    static let enabledKey = "showPill"

    private(set) var phase = Phase.hidden
    /// When the current shake (cancel / error) started, for the view's animation.
    private(set) var shakeStart = Date.distantPast
    let meter: LevelMeter

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(meter: LevelMeter) {
        self.meter = meter
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: Events from the dictation controller

    func listening() {
        guard isEnabled else { return }
        show()
        phase = .listening(live: false)
    }

    func micLive() {
        if case .listening = phase { phase = .listening(live: true) }
    }

    func transcribing() {
        guard phase != .hidden else { return }
        phase = .transcribing
    }

    func finished() {
        hide(after: .zero)
    }

    func cancelled() {
        guard phase != .hidden else { return }
        shakeStart = .now
        phase = .cancelled
        hide(after: .milliseconds(350))
    }

    func failed() {
        guard isEnabled else { return }
        show()
        shakeStart = .now
        phase = .failed
        hide(after: .milliseconds(700))
    }

    // MARK: Window

    private func show() {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            phase = .hidden
            // Let the collapse animation finish before removing the window.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    private static let panelSize = CGSize(width: 220, height: 72)

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // drawn by SwiftUI so it follows the capsule
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(pill: self))
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        return panel
    }

    /// Bottom-center of the screen you're working on, just above the Dock.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - Self.panelSize.width / 2, y: frame.minY + 6))
    }
}

// MARK: - View

private struct PillView: View {
    let pill: FlowPill

    private static let barCount = 11
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 3
    private static let minBar: CGFloat = 3
    private static let maxBar: CGFloat = 18

    private var isVisible: Bool { pill.phase != .hidden }

    var body: some View {
        TimelineView(.animation(paused: !isVisible)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(pill.meter.level)
            HStack(spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    Capsule()
                        .fill(.white)
                        .frame(width: Self.barWidth, height: barHeight(i, t: t, level: level))
                        .opacity(barOpacity(i, t: t))
                }
            }
            .frame(height: Self.maxBar)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(capsuleBackground)
            .offset(x: shakeOffset(at: context.date))
        }
        .scaleEffect(isVisible ? 1 : 0.4, anchor: .bottom)
        .opacity(isVisible ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isVisible)
        .animation(.easeOut(duration: 0.15), value: pill.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
        .accessibilityHidden(true)
    }

    private var capsuleBackground: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(tint.opacity(0.72)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    private var tint: Color {
        pill.phase == .failed ? Color(red: 0.55, green: 0.08, blue: 0.08) : .black
    }

    /// Center-weighted envelope × the mic level, with a per-bar wobble so it looks alive.
    private func barHeight(_ i: Int, t: TimeInterval, level: CGFloat) -> CGFloat {
        switch pill.phase {
        case .listening(live: true):
            let center = CGFloat(Self.barCount - 1) / 2
            let envelope = 0.35 + 0.65 * (1 - abs(CGFloat(i) - center) / (center + 1))
            let wobble = 0.6 + 0.4 * sin(t * (7 + Double(i) * 1.3) + Double(i) * 1.7)
            let idle = 0.08 * (0.5 + 0.5 * sin(t * 2.4 + Double(i) * 0.8)) // a faint breath in silence
            let amount = max(level * envelope * wobble, idle)
            return Self.minBar + (Self.maxBar - Self.minBar) * amount
        default:
            return Self.minBar
        }
    }

    private func barOpacity(_ i: Int, t: TimeInterval) -> Double {
        switch pill.phase {
        case .listening(live: false):
            return 0.5 // waiting for the mic
        case .transcribing:
            // A highlight sweeping left to right while the text is produced.
            return 0.35 + 0.65 * max(0, sin(t * 7 - Double(i) * 0.55))
        default:
            return 1
        }
    }

    private func shakeOffset(at date: Date) -> CGFloat {
        guard pill.phase == .cancelled || pill.phase == .failed else { return 0 }
        let elapsed = date.timeIntervalSince(pill.shakeStart)
        guard elapsed < 0.35 else { return 0 }
        return sin(elapsed * 55) * 6 * (1 - elapsed / 0.35)
    }
}
