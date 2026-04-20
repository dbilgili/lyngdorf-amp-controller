import SwiftUI
import Network

struct MainView: View {
    @ObservedObject var ampManager: LyngdorfManager

    var body: some View {
        VStack {
            if !ampManager.isConnected || ampManager.isConnecting {
                ConnectionPanel(ampManager: ampManager)
            } else if ampManager.statusMessage == "Standby" {
                PowerOnPanel(ampManager: ampManager)
            } else if ampManager.statusMessage == "Awake" {
                ControlPanel(ampManager: ampManager)
            } else {
                ProgressView("Connecting...")
                    .frame(width: 200, height: 150)
            }
        }
        .padding()
    }
}

struct ControlPanel: View {
    @ObservedObject var ampManager: LyngdorfManager
    
    let volumeBtnSize: CGFloat = 28
    @State private var prevTapCount = 0
    @State private var nextTapCount = 0

    var body: some View {
        VStack(spacing: 16) {
            // Now Playing: artwork left, info + controls right
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: ampManager.trackArtworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: 175, height: 175)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 10) {
                    // Track info, centered
                    VStack(spacing: 2) {
                        if ampManager.trackTitle.isEmpty {
                            Text(" ").font(.system(size: 13, weight: .semibold))
                            Text(" ").font(.system(size: 11))
                        } else {
                            MarqueeText(text: ampManager.trackTitle, font: .system(size: 13, weight: .semibold))
                            if ampManager.trackArtist.isEmpty {
                                Text(" ").font(.system(size: 11))
                            } else {
                                MarqueeText(text: ampManager.trackArtist, font: .system(size: 11), color: .secondary)
                            }
                        }
                    }

                    // Transport controls
                    HStack(spacing: 20) {
                        Button(action: {
                            ampManager.sendCommand("PREV")
                            prevTapCount += 1
                        }) {
                            Image(systemName: "backward.fill")
                                .font(.title3)
                                .symbolEffect(.bounce, value: prevTapCount)
                        }

                        Button(action: { ampManager.togglePlayPause() }) {
                            Image(systemName: ampManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .contentTransition(.symbolEffect(.replace, options: .speed(1.5)))
                                .font(.system(size: 36))
                        }

                        Button(action: {
                            ampManager.sendCommand("NEXT")
                            nextTapCount += 1
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                                .symbolEffect(.bounce, value: nextTapCount)
                        }
                    }
                    .buttonStyle(.plain)

                    // Progress bar
                    if ampManager.playbackPosition >= 0 {
                        PlaybackProgressBar(
                            position: ampManager.playbackPosition,
                            duration: ampManager.playbackDuration
                        )
                    }

                    Spacer(minLength: 0)

                    // Volume Section
                    HStack {
                        NativeContinuousButton(icon: "speaker.wave.1.fill", size: volumeBtnSize) {
                            ampManager.sendCommand("VOLDN")
                        }
                        .frame(width: volumeBtnSize, height: volumeBtnSize)

                        Spacer()

                        Text(ampManager.currentVolume)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .opacity(ampManager.isMuted ? 0.2 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: ampManager.isMuted)
                            .onTapGesture { ampManager.sendCommand("MUTE") }

                        Spacer()

                        NativeContinuousButton(icon: "speaker.wave.3.fill", size: volumeBtnSize) {
                            ampManager.sendCommand("VOLUP")
                        }
                        .frame(width: volumeBtnSize, height: volumeBtnSize)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 170)
            }

            Divider()

            HStack {
                Button(action: { ampManager.sendCommand("PWROFF") }) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .black))
                }
                .buttonStyle(.plain)
                Text("TDAI-1120").font(.caption2).foregroundColor(.secondary).padding(.top, 1)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Marquee Text

struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var scrollStart: Date = .distantFuture

    private var overflows: Bool { textWidth > containerWidth && containerWidth > 0 }
    private let gap: CGFloat = 40
    private let speed: Double = 30 // points per second
    private let pause: TimeInterval = 1.5

    var body: some View {
        GeometryReader { geo in
            let _ = updateContainerWidth(geo.size.width)
            if overflows {
                TimelineView(.animation) { context in
                    HStack(spacing: gap) {
                        textView
                        textView
                    }
                    .offset(x: currentOffset(at: context.date))
                }
                .onAppear { scheduleStart() }
                .onChange(of: text) { scheduleStart() }
            } else {
                textView
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: textHeight)
        .clipped()
    }

    private var textView: some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { geo in
                Color.clear.onAppear { textWidth = geo.size.width }
                    .onChange(of: text) { textWidth = geo.size.width }
            })
    }

    private var textHeight: CGFloat {
        let nsFont = NSFont.systemFont(ofSize: 12)
        return nsFont.ascender - nsFont.descender + nsFont.leading + 2
    }

    private func updateContainerWidth(_ width: CGFloat) {
        if containerWidth != width {
            DispatchQueue.main.async { containerWidth = width }
        }
    }

    private func scheduleStart() {
        scrollStart = Date().addingTimeInterval(pause)
    }

    private func currentOffset(at date: Date) -> CGFloat {
        guard date >= scrollStart else { return 0 }
        let elapsed = date.timeIntervalSince(scrollStart)
        let cycle = textWidth + gap
        guard cycle > 0 else { return 0 }
        let pos = (elapsed * speed).truncatingRemainder(dividingBy: cycle)
        return -pos
    }
}

// MARK: - Playback Progress Bar
// Two modes:
//   • duration >= 0 → full progress bar with elapsed / total
//   • duration < 0  → elapsed time only with animated streaming indicator

struct PlaybackProgressBar: View {
    let position: Double
    let duration: Double

    private var hasDuration: Bool { duration > 0 }
    private var progress: Double {
        guard hasDuration else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            if hasDuration {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: geo.size.width * progress, height: 3)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 10)
                .animation(.easeOut(duration: 0.15), value: progress)

                HStack {
                    Text(formatTime(position))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(duration))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 3)
                    .frame(height: 10)

                HStack {
                    Text(formatTime(position))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct StreamingDot: View {
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Circle()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 5, height: 5)
                .offset(x: offset)
                .frame(maxHeight: .infinity, alignment: .center)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                        offset = geo.size.width - 5
                    }
                }
        }
    }
}

struct PulseDot: View {
    @State private var opacity: Double = 1.0

    var body: some View {
        Circle()
            .fill(Color.red.opacity(0.8))
            .frame(width: 5, height: 5)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    opacity = 0.2
                }
            }
    }
}

// MARK: - Unchanged views below

struct NativeContinuousButton: NSViewRepresentable {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.title = ""
        button.bezelStyle = .shadowlessSquare
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        let hostingView = CenteredIconView(frame: button.bounds)
        hostingView.iconName = icon
        hostingView.btnSize = size
        button.addSubview(hostingView)
        button.target = context.coordinator
        button.action = #selector(Coordinator.handleAction)
        button.isContinuous = true
        button.setPeriodicDelay(0.5, interval: 0.05)
        button.sendAction(on: [.leftMouseDown, .periodic])
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        if let customView = nsView.subviews.first as? CenteredIconView {
            customView.needsDisplay = true
        }
    }

    class CenteredIconView: NSView {
        var iconName: String = ""
        var btnSize: CGFloat = 56

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let isDark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let circleColor = isDark ? NSColor.white.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.85)
            circleColor.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            let iconScale = btnSize * 0.4
            let config = NSImage.SymbolConfiguration(pointSize: iconScale, weight: .semibold)
            if let baseImg = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let tintedImg = baseImg.copy() as! NSImage
                tintedImg.isTemplate = false
                let iconColor = isDark ? NSColor.black : NSColor.white
                tintedImg.lockFocus()
                iconColor.set()
                NSRect(origin: .zero, size: tintedImg.size).fill(using: .sourceAtop)
                tintedImg.unlockFocus()
                let x = (bounds.width - tintedImg.size.width) / 2
                let y = (bounds.height - tintedImg.size.height) / 2
                tintedImg.draw(in: NSRect(origin: CGPoint(x: x, y: y), size: tintedImg.size),
                               from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func handleAction() { action() }
    }
}

struct ConnectionPanel: View {
    @ObservedObject var ampManager: LyngdorfManager
    var body: some View {
        VStack(spacing: 15) {
            if ampManager.isConnecting {
                ProgressView("Connecting...")
            } else if ampManager.availableAmps.count > 1 {
                Text("Select Device").font(.headline)
                ForEach(ampManager.availableAmps, id: \.self) { endpoint in
                    Button(action: { ampManager.connect(to: endpoint) }) {
                        Text(friendlyName(for: endpoint)).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: 200, height: 150)
        
    }
    func friendlyName(for endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return "Unknown"
    }
}

struct PowerOnPanel: View {
    @ObservedObject var ampManager: LyngdorfManager
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.stars.fill").font(.system(size: 40)).foregroundColor(.blue)
            Text("Amp is in Standby").font(.headline)
            Button("Wake Up Amp") {
                ampManager.sendCommand("PWRON")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { ampManager.sendCommand("VOL?") }
            }.buttonStyle(.borderedProminent).tint(.green)
        }.frame(width: 200, height: 200)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
