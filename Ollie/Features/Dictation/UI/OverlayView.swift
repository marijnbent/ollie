import AppKit
import SwiftUI

struct RecorderWidgetPresentation: Equatable {
    let streamedText: String?

    var showsStreamedText: Bool {
        streamedText != nil
    }

    init(
        transcript: String,
        recordingPhase: RecordingPhase,
        isLiveTranscriptEnabled: Bool
    ) {
        let streamedText = transcript.trimmed
        guard isLiveTranscriptEnabled,
              recordingPhase == .recording,
              !streamedText.isEmpty else {
            self.streamedText = nil
            return
        }
        self.streamedText = streamedText
    }
}

enum RecorderWidgetMeter {
    static let quietThreshold: CGFloat = 0.12

    static func visibleLevel(for level: CGFloat) -> CGFloat {
        let normalizedLevel = min(max(level, 0), 1)
        guard normalizedLevel > quietThreshold else { return 0 }
        return (normalizedLevel - quietThreshold) / (1 - quietThreshold)
    }

    static func smoothedLevel(current: CGFloat, target: CGFloat) -> CGFloat {
        let normalizedCurrent = min(max(current, 0), 1)
        let normalizedTarget = min(max(target, 0), 1)
        let difference = normalizedTarget - normalizedCurrent
        guard abs(difference) >= 0.004 else { return normalizedTarget }
        let response: CGFloat = difference > 0 ? 0.32 : 0.18
        return normalizedCurrent + difference * response
    }
}

struct RecorderWidgetTranscriptWord: Identifiable, Equatable {
    let id: Int
    let text: String
}

enum RecorderWidgetTranscriptWords {
    static let visibleLimit = 24

    static func project(_ transcript: String) -> [RecorderWidgetTranscriptWord] {
        let words = transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let firstVisibleIndex = max(0, words.count - visibleLimit)
        return words.enumerated().dropFirst(firstVisibleIndex).map {
            RecorderWidgetTranscriptWord(id: $0.offset, text: $0.element)
        }
    }
}

enum RecorderWidgetTranscriptEmphasis {
    static let settleDelay: TimeInterval = 0.6

    static func activeOpacity(distanceFromNewest: Int) -> Double {
        switch distanceFromNewest {
        case 0: 0.94
        case 1: 0.76
        case 2: 0.6
        default: 0.36
        }
    }

    static func settledOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.62 }
        guard count > 2 else { return 0.46 }
        let distanceToEdge = min(index, count - index - 1)
        let distanceToCenter = max(1, (count - 1) / 2)
        let progress = min(1, Double(distanceToEdge) / Double(distanceToCenter))
        return 0.36 + progress * 0.36
    }
}

enum RecorderWidgetLayout {
    static let maximumWidth: CGFloat = 260
    static let horizontalTextPadding: CGFloat = 28
    static let leadingFadeWidth: CGFloat = 12
    static let transcriptFontSize: CGFloat = 11
    static let wordSpacing: CGFloat = 3

    static func measuredTextWidth(for transcript: String) -> CGFloat? {
        let words = RecorderWidgetTranscriptWords.project(transcript)
        guard !words.isEmpty else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: transcriptFontSize, weight: .regular),
        ]
        let wordsWidth = words.reduce(CGFloat.zero) { width, word in
            width + (word.text as NSString).size(withAttributes: attributes).width
        }
        return wordsWidth + CGFloat(words.count - 1) * wordSpacing
    }

    static func nextWidth(
        compactWidth: CGFloat,
        measuredTextWidth: CGFloat?,
        previousWidth: CGFloat?
    ) -> CGFloat {
        guard let measuredTextWidth else { return compactWidth }
        let desiredWidth = min(
            maximumWidth,
            max(compactWidth, ceil(measuredTextWidth) + horizontalTextPadding)
        )
        return max(previousWidth ?? compactWidth, desiredWidth)
    }

    static func shouldFadeLeadingEdge(
        measuredTextWidth: CGFloat?,
        availableWidth: CGFloat
    ) -> Bool {
        guard let measuredTextWidth else { return false }
        return measuredTextWidth > availableWidth + 0.5
    }
}

struct OverlayView: View {
    @Bindable var sessionState: DictationSessionState
    @Bindable var settingsStore: DictationSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onCycleLanguage: () -> Void
    @State private var appear = false

    private var isEnhancing: Bool { sessionState.overlayLabel == "Enhancing" }

    private var presentation: RecorderWidgetPresentation {
        RecorderWidgetPresentation(
            transcript: sessionState.lastTranscript,
            recordingPhase: sessionState.recordingPhase,
            isLiveTranscriptEnabled: settingsStore.showLiveTranscriptInRecorderWidget
        )
    }

    private var cardCornerRadius: CGFloat {
        presentation.showsStreamedText ? 18 : 17
    }

    private var contentAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    private var transcriptRowTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .identity,
            removal: .opacity
        )
    }

    var body: some View {
        VStack(alignment: .center, spacing: presentation.showsStreamedText ? 4 : 0) {
            if let streamedText = presentation.streamedText {
                StreamingTranscriptText(text: streamedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(transcriptRowTransition)
            }

            HStack(spacing: 8) {
                if settingsStore.showLanguageInRecorderWidget {
                    LanguageCycleButton(
                        language: settingsStore.transcriptionProvider.normalizedLanguage(
                            settingsStore.deepgramLanguage
                        ),
                        action: onCycleLanguage
                    )
                }

                RecordingStatusOrb(
                    audioMeter: sessionState.audioMeter,
                    isEnhancing: isEnhancing
                )

                if let appIcon = sessionState.overlayAppIcon {
                    OverlayAppIcon(icon: appIcon)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, presentation.showsStreamedText ? 8 : 5)
        .modifier(OverlayCardSurface(cornerRadius: cardCornerRadius))
        .animation(contentAnimation, value: presentation.showsStreamedText)
        .scaleEffect(appear ? 1.0 : 0.96)
        .opacity(appear ? 1.0 : 0.0)
        .offset(y: appear ? 0 : -8)
        .id(sessionState.overlayPulseID)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72, blendDuration: 0.2)) {
                appear = sessionState.overlayVisible
            }
        }
        .onDisappear {
            appear = false
        }
        .onChange(of: sessionState.overlayVisible) { _, visible in
            if visible {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72, blendDuration: 0.2)) {
                    appear = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    appear = false
                }
            }
        }
    }

}

private struct StreamingTranscriptText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    @State private var words: [RecorderWidgetTranscriptWord] = []
    @State private var entranceDelays: [Int: Double] = [:]

    private var layoutAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    var body: some View {
        TranscriptWordLayout(spacing: RecorderWidgetLayout.wordSpacing) {
            ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                StreamingTranscriptWord(
                    word: word,
                    index: index,
                    wordCount: words.count,
                    delay: entranceDelays[word.id] ?? 0
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)
        .clipped()
        .mask(TranscriptLeadingFadeMask(text: text))
        .animation(layoutAnimation, value: words.last?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onAppear {
            updateWords(from: text)
        }
        .onChange(of: text) { _, updatedText in
            updateWords(from: updatedText)
        }
    }

    private func updateWords(from transcript: String) {
        let updatedWords = RecorderWidgetTranscriptWords.project(transcript)
        let existingIDs = Set(words.map(\.id))
        let newIDs = updatedWords.lazy.filter { !existingIDs.contains($0.id) }.map(\.id)
        entranceDelays = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { index, id in
            (id, min(Double(index) * 0.025, 0.075))
        })
        words = updatedWords
    }
}

private struct TranscriptLeadingFadeMask: View {
    let text: String

    var body: some View {
        GeometryReader { geometry in
            if RecorderWidgetLayout.shouldFadeLeadingEdge(
                measuredTextWidth: RecorderWidgetLayout.measuredTextWidth(for: text),
                availableWidth: geometry.size.width
            ) {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .white],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: min(RecorderWidgetLayout.leadingFadeWidth, geometry.size.width))

                    Color.white
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Color.white
            }
        }
    }
}

private struct StreamingTranscriptWord: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let word: RecorderWidgetTranscriptWord
    let index: Int
    let wordCount: Int
    let delay: Double
    @State private var isVisible = false
    @State private var isRecent = true

    private var textOpacity: Double {
        if isRecent {
            return RecorderWidgetTranscriptEmphasis.activeOpacity(
                distanceFromNewest: wordCount - index - 1
            )
        }
        return RecorderWidgetTranscriptEmphasis.settledOpacity(index: index, count: wordCount)
    }

    var body: some View {
        ZStack {
            Text(word.text)
                .font(.system(size: RecorderWidgetLayout.transcriptFontSize, weight: .regular))
                .opacity(isRecent ? 0 : 1)

            Text(word.text)
                .font(.system(size: RecorderWidgetLayout.transcriptFontSize, weight: .medium))
                .opacity(isRecent ? 1 : 0)
        }
        .foregroundStyle(Color.primary.opacity(textOpacity))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(isVisible || reduceMotion ? 1 : 0)
        .offset(y: isVisible || reduceMotion ? 0 : 2)
        .onAppear {
            guard !reduceMotion else {
                isVisible = true
                return
            }
            withAnimation(
                .spring(response: 0.24, dampingFraction: 0.84)
                    .delay(delay)
            ) {
                isVisible = true
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                isVisible = true
            }
        }
        .task(id: word.text) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isRecent = true
            }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(RecorderWidgetTranscriptEmphasis.settleDelay * 1_000_000_000)
                )
            } catch {
                return
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                isRecent = false
            }
        }
    }
}

private struct TranscriptWordLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let contentWidth = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, sizes.count - 1)) * spacing
        let contentHeight = sizes.map(\.height).max() ?? 0
        return CGSize(
            width: proposal.width ?? contentWidth,
            height: proposal.height ?? contentHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let contentWidth = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, sizes.count - 1)) * spacing
        var x = contentWidth > bounds.width
            ? bounds.maxX - contentWidth
            : bounds.midX - contentWidth / 2

        for (subview, size) in zip(subviews, sizes) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
        }
    }
}

struct OverlayCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(OverlayGlassBackground(cornerRadius: cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(fallbackBorder)
        }
    }

    private var fallbackBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.34 : 0.58),
                        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

private struct LanguageCycleButton: View {
    let language: DeepgramLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if language == .automatic {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
            } else {
                Text(language.menuBarAbbreviation)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(RecorderWidgetButtonStyle())
        .help("Language: \(language.displayName)")
        .accessibilityLabel("Transcription language")
        .accessibilityValue(language.displayName)
    }
}

struct RecorderWidgetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RecorderWidgetButtonLabel(label: configuration.label)
    }
}

private struct RecorderWidgetButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    let label: ButtonStyleConfiguration.Label
    private let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    @ViewBuilder
    var body: some View {
        let control = label
            .frame(width: 24, height: 24)
            .contentShape(shape)
            .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.88 : 0.66))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            control
                .background(shape.fill(Color.primary.opacity(fallbackOpacity)))
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
        } else {
            control.glassEffect(.clear.interactive(), in: shape)
        }
    }

    private var fallbackOpacity: Double {
        isHovered ? (colorScheme == .dark ? 0.14 : 0.08) : (colorScheme == .dark ? 0.07 : 0.035)
    }
}

private struct DictationBackdropView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? .windowBackground
            : material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

private struct OverlayGlassBackground: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var highlightOpacity: Double {
        if reduceTransparency {
            return 0.04
        }

        return colorScheme == .dark ? 0.14 : 0.16
    }

    private var glowOpacity: Double {
        guard !reduceTransparency else { return 0 }
        return colorScheme == .dark ? 0.08 : 0.07
    }

    var body: some View {
        ZStack {
            DictationBackdropView(material: .hudWindow)

            if reduceTransparency {
                Color(NSColor.windowBackgroundColor)
                    .opacity(0.95)
            }

            LinearGradient(
                colors: [
                    Color.white.opacity(highlightOpacity),
                    Color.white.opacity(0.03),
                    Color.white.opacity(0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(glowOpacity),
                    Color.white.opacity(0)
                ],
                center: .topLeading,
                startRadius: 4,
                endRadius: 56
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct OverlayAppIcon: View {
    let icon: NSImage

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct RecordingStatusOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var audioMeter: AudioMeterState
    let isEnhancing: Bool
    @State private var targetLevel: CGFloat = 0
    @State private var displayedLevel: CGFloat = 0
    @State private var enhancementMotion = false
    private let ticker = Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RecordingHalo(level: displayedLevel)
                .opacity(isEnhancing ? 0 : 1)
            EnhancementHalo(isMoving: enhancementMotion)
                .opacity(isEnhancing ? 1 : 0)
            RecordingDot()
        }
        .frame(width: 32, height: 32)
        .onAppear {
            let visibleLevel = RecorderWidgetMeter.visibleLevel(for: audioMeter.level)
            targetLevel = visibleLevel
            displayedLevel = visibleLevel
            enhancementMotion = isEnhancing && !reduceMotion
        }
        .onChange(of: audioMeter.level) { _, updatedLevel in
            targetLevel = RecorderWidgetMeter.visibleLevel(for: updatedLevel)
            if reduceMotion {
                displayedLevel = targetLevel
            }
        }
        .onChange(of: isEnhancing) { _, enhancing in
            enhancementMotion = enhancing && !reduceMotion
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                displayedLevel = targetLevel
            }
            enhancementMotion = isEnhancing && !shouldReduceMotion
        }
        .onReceive(ticker) { _ in
            guard !reduceMotion, !isEnhancing, displayedLevel != targetLevel else { return }
            displayedLevel = RecorderWidgetMeter.smoothedLevel(
                current: displayedLevel,
                target: targetLevel
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level")
    }
}

private struct RecordingHalo: View {
    let level: CGFloat

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.red.opacity(0.42 + 0.26 * level),
                        Color.red.opacity(0.08 + 0.04 * level),
                    ],
                    center: .center,
                    startRadius: 2,
                    endRadius: 16
                )
            )
            .frame(width: 18 + 12 * level, height: 18 + 12 * level)
    }
}

private struct EnhancementHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isMoving: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.red.opacity(0.26),
                            Color.pink.opacity(0.12),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 3,
                        endRadius: 16
                    )
                )
                .frame(
                    width: isMoving ? 25 : 20,
                    height: isMoving ? 25 : 20
                )
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: isMoving
                )

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.red.opacity(0.9),
                            Color.pink.opacity(0.72),
                            Color.orange.opacity(0.5),
                            Color.clear,
                            Color.red.opacity(0.9),
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )
                .frame(width: 21, height: 21)
                .rotationEffect(.degrees(isMoving ? 360 : 0))
                .animation(
                    reduceMotion ? nil : .linear(duration: 1.25).repeatForever(autoreverses: false),
                    value: isMoving
                )
        }
    }
}

private struct RecordingDot: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.red, Color.red.opacity(0.72)],
                    center: .center,
                    startRadius: 1,
                    endRadius: 4
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: Color.red.opacity(0.5), radius: 3)
    }
}
