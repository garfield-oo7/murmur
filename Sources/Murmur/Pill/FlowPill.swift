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
    static let liveTextKey = "showLiveText"

    enum Position: String, CaseIterable, Identifiable {
        case bottom, center
        var id: String { rawValue }
        var title: String { self == .center ? "Center of screen" : "Bottom of screen" }

        static let key = "pillPosition"
        static var current: Position {
            UserDefaults.standard.string(forKey: key).flatMap(Position.init) ?? .bottom
        }
    }

    private(set) var phase = Phase.hidden
    /// Words recognized so far while dictating: settled text and the current guess.
    private(set) var caption: (settled: String, pending: String)?
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

    private var showsLiveText: Bool {
        UserDefaults.standard.object(forKey: Self.liveTextKey) as? Bool ?? true
    }

    // MARK: Events from the dictation controller

    func listening() {
        guard isEnabled else { return }
        show()
        phase = .listening(live: false)
        caption = nil
    }

    func liveText(settled: String, pending: String) {
        guard showsLiveText, phase == .listening(live: true) || phase == .transcribing else { return }
        caption = settled.isEmpty && pending.isEmpty ? nil : (settled, pending)
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
            caption = nil
            // Let the collapse animation finish before removing the window.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    /// Room for the capsule plus the live-text caption above it; the panel is
    /// transparent and ignores the mouse, so the empty part is invisible.
    private static let panelSize = CGSize(width: 560, height: 150)

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

    /// Middle of the screen you're working on, or bottom-center just above the Dock.
    /// The capsule sits 14 pt above the panel's bottom edge, hence the offsets.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let y = switch Position.current {
        case .center: frame.midY - 14 - 18
        case .bottom: frame.minY + 6
        }
        panel.setFrameOrigin(CGPoint(x: frame.midX - Self.panelSize.width / 2, y: y))
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
        VStack(spacing: 8) {
            if isVisible, let caption = pill.caption {
                CaptionView(settled: caption.settled, pending: caption.pending)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            bars
        }
        .animation(.easeOut(duration: 0.2), value: pill.caption == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
        .accessibilityHidden(true)
    }

    private var bars: some View {
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

/// The last couple of lines of what you've said: settled words in white, the
/// recognizer's current guess dimmed.
private struct CaptionView: View {
    let settled: String
    let pending: String

    /// About two lines at this width; older words scroll off the front.
    private static let maxCharacters = 130

    var body: some View {
        Text(attributed)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(2, reservesSpace: false)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 480, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            )
            .environment(\.colorScheme, .dark)
    }

    private var attributed: AttributedString {
        var (settled, pending) = (settled, pending.trimmingCharacters(in: .whitespaces))
        if !settled.isEmpty, !pending.isEmpty, settled.last?.isWhitespace == false { settled += " " }
        // Keep the tail, cutting at a word boundary.
        let overflow = settled.count + pending.count - Self.maxCharacters
        if overflow > 0 {
            if overflow < settled.count {
                var tail = settled.dropFirst(overflow)
                if let space = tail.firstIndex(of: " ") { tail = tail[tail.index(after: space)...] }
                settled = "…" + tail
            } else {
                settled = ""
                pending = "…" + pending.suffix(Self.maxCharacters)
            }
        }
        var text = AttributedString(settled)
        text.foregroundColor = .white
        var guess = AttributedString(pending)
        guess.foregroundColor = .white.opacity(0.78)
        text.append(guess)
        return text
    }
}
