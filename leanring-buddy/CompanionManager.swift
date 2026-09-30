//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state machine and mode router. Owns push-to-talk (dictation manager +
//  global shortcut monitor), the cursor overlay, the drawing layer, speech output
//  and the two mode pipelines. On every transcript it captures the display under
//  the cursor, runs on-device OCR, decides between Data and General mode, and
//  hands results to the drawing layer and the voice.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI
import NaturalLanguage
import Vision

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    /// True while the Agent (or its rehearsal) is driving the screen. The notch
    /// shows "Acting" on its wings for as long as this is set.
    @Published private(set) var isActing = false
    /// True while a voice is actually playing. Kept by a small poll of the speech
    /// clients, because the voice state flips to idle whenever the buddy points.
    @Published private(set) var isSpeaking = false
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of an element the buddy should fly
    /// to and point at. Observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the element is on.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Speech bubble text for the pointing animation.
    @Published var detectedElementBubbleText: String?

    /// Whether the blue cursor overlay is currently visible on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    // MARK: - Octo state

    /// Operating mode chosen in the panel. Persisted.
    // Key versioned so older builds' persisted choice (e.g. "General" from testing)
    // does not silently keep Agent/Rx routing off after an update.
    @Published private(set) var selectedMode: SounderMode = SounderMode(rawValue: UserDefaults.standard.string(forKey: "sounderSelectedMode_v3") ?? "") ?? .automatic

    /// Whether Data mode may fall back to select-all/copy when OCR confidence is low. Persisted.
    @Published private(set) var isClipboardFallbackEnabled: Bool = UserDefaults.standard.object(forKey: "sounderClipboardFallbackEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "sounderClipboardFallbackEnabled")

    /// On-device transcription (Apple Speech, transcript ready the moment the key is
    /// released) instead of Fireworks Whisper (cloud upload, 2-10s in testing). Default on. Persisted.
    @Published private(set) var isOfflineVoiceEnabled: Bool = UserDefaults.standard.object(forKey: "sounderOfflineVoiceEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "sounderOfflineVoiceEnabled")

    @Published private(set) var isAnalysisServiceReachable = false
    @Published private(set) var isWorkerReachable = false
    /// The proxy holds a TypeSafe key: Jev decides intents and checks agent steps.
    @Published private(set) var isJevConfigured = false
    @Published private(set) var lastInteractionReport: SounderInteractionReport?
    /// The last few runs, newest first, for the large card's history.
    @Published private(set) var recentInteractionReports: [SounderInteractionReport] = []

    /// Caption: the spoken text, revealed progressively at speaking pace so the
    /// person can read along (the model returns whole answers, not tokens).
    @Published private(set) var captionText: String = ""
    private var captionFullText = ""
    private var captionRevealProgress: Double = 0
    private var captionRevealTimer: Timer?
    private var captionHideTask: Task<Void, Never>?
    private static let captionWordsPerSecond: Double = 2.8
    private static let captionRevealTicksPerSecond: Double = 20

    /// Spatial context: cursor positions (global AppKit coords) sampled while the
    /// hotkey is held. Drawn as a trail by the overlay; the bounding box becomes
    /// the region of interest for the question when it is big enough to be a gesture.
    @Published private(set) var gesturePathPointsGlobal: [CGPoint] = []
    /// The visible trail: recent cursor positions with the time they were sampled.
    /// Points older than `gestureTrailLifetime` are dropped every tick, so the
    /// trail fades from the tail while the raw path above still defines the region.
    @Published private(set) var gestureTrailPoints: [GestureTrailPoint] = []
    static let gestureTrailLifetime: TimeInterval = 1.1
    private var gestureTrailFadeTimer: Timer?
    private var gestureSamplingTimer: Timer?
    private var pendingGestureBoundsGlobal: CGRect?
    private var lastRegionOfInterestInCapturePixels: CGRect?
    private static let minimumGestureSizeInPoints: CGFloat = 30
    @Published private(set) var isRunningCalibration = false

    let buddyDictationManager: BuddyDictationManager
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let drawingLayerModel = DrawingLayerModel()
    /// Clickable paper / image / video card the buddy holds up next to itself.
    private let mediaCardPanelManager = MediaCardPanelManager()
    /// Fast typed decisions (intent, "did that work", "is this irreversible").
    private let jevDecisionClient: JevDecisionClient
    /// Top-right card naming the task and ticking off the agent's steps.
    private let agentTaskCardPanelManager = AgentTaskCardPanelManager()
    /// Notes, links and images the user pinned in the notch; folded into every prompt.
    let userContextStore = UserContextStore()
    /// Rolling in-memory buffer of low-res frames + OCR for "what did that say five minutes ago?".
    let screenHistoryRecorder = ScreenHistoryRecorder()
    private let rewindPanelManager = RewindPanelManager()
    /// Whiteboard in the margins: conceptual answers get a sketched diagram.
    private let whiteboardPipeline: WhiteboardPipeline
    private let whiteboardPanelManager = WhiteboardPanelManager()
    /// Translate in place.
    private let translatePipeline: TranslatePipeline
    /// Camera as context: live webcam preview + OCR on a grabbed frame.
    private let cameraContextPanelManager = CameraContextPanelManager()
    /// Make-readable structure and rewrite-in-place.
    private let readabilityPipeline: ReadabilityPipeline
    /// Read-aloud session: survives hotkey interruptions so "skip", "explain that"
    /// and "continue" pick up where the voice stopped.
    private var readAloudScript: ReadAloudScript?
    private var readAloudIndex = 0
    private var readAloudGeometry: CaptureGeometry?
    private var isReadingAloud = false
    /// Agent rehearsal: the ghost cursor's position (global AppKit) and step label
    /// while a plan is being acted out, and the plan waiting for "go".
    @Published private(set) var ghostCursorGlobalPoint: CGPoint?
    @Published private(set) var ghostStepLabel: String = ""
    private struct PendingRehearsal {
        let task: String
        let steps: [AgentPlanStep]
        let researchNotes: ResearchNotes?
        let screenAnalysis: ScreenAnalysis
    }
    private var pendingRehearsal: PendingRehearsal?
    private var rehearsalTimeoutTask: Task<Void, Never>?
    /// Guided path: a numbered route the user clicks through; lights up as they go.
    private var guidedRouteElements: [ScreenElement] = []
    private var guidedRouteLabels: [String] = []
    private var guidedRouteGeometry: CaptureGeometry?
    private var guidedRouteStep = 0
    private var guidedRouteClickMonitors: [Any] = []
    /// Where the cursor sat still while the hotkey was held, if it did (global AppKit points).
    private var pendingDwellPointGlobal: CGPoint?
    private var dwellAnchorPointGlobal: CGPoint?
    private var dwellAnchorStartedAt: Date?
    private var holdStartedAt: Date?
    private var lastTranscriptReceivedAt = Date.distantPast
    private var dwellFallbackTask: Task<Void, Never>?
    /// Hold still for this long (while holding the hotkey) to ask without speaking.
    private static let dwellSeconds: TimeInterval = 0.9
    private static let dwellRadiusInPoints: CGFloat = 8
    /// Snapshot of the pinned context taken when an interaction starts.
    private var userContextForCurrentInteraction: UserContextBundle?

    private let chatClient: any ChatModelClient
    private let analysisClient: AnalysisServiceClient
    private let speechOutput: any SpeechOutputClient
    /// Used only when the configured speech provider fails (e.g. ElevenLabs credits).
    private lazy var fallbackSpeechOutput: SystemSpeechOutputClient = SystemSpeechOutputClient()
    private let generalModePipeline: GeneralModePipeline
    private let clinicalModePipeline: ClinicalModePipeline
    private let agentModePipeline: AgentModePipeline
    private let researchAgent: ResearchAgent
    private let clinicalLexicon = ClinicalLexicon.load()
    private let screenChangeWatcher = ScreenChangeWatcher()

    var speechOutputDisplayName: String { speechOutput.displayName }

    /// Conversation history for General mode so follow-ups make sense.
    private var conversationHistory: [ChatModelPriorTurn] = []


    /// Everything read off the screen for one interaction.
    private struct ScreenAnalysis {
        let capture: SounderScreenCapture
        let textLines: [RecognizedTextLine]
        /// OCR lines plus accessibility elements (kind "ax:<role>"), one id space.
        let elements: [ScreenElement]
        /// The accessibility handles behind the "ax:" elements, by element id.
        let accessibilityElementsByID: [Int: AccessibilityElement]
        let clinicalReading: ClinicalScreenReading
        let regionOfInterestInCapturePixels: CGRect?
        let captureSeconds: Double
        let ocrSeconds: Double
    }

    /// Accessibility elements of the frontmost app, converted to capture pixels and
    /// appended after the OCR elements. Static text that OCR already found is
    /// skipped; controls are always kept because their role and label are exact.
    private static func mergeAccessibilityElements(into ocrElements: [ScreenElement], capture: SounderScreenCapture) async -> ([ScreenElement], [Int: AccessibilityElement]) {
        let displayFrame = capture.geometry.displayFrame
        guard let primaryScreen = NSScreen.screens.first else { return (ocrElements, [:]) }
        // AX frames are global CG points (top-left of the primary display).
        let displayFrameCG = CGRect(x: displayFrame.minX, y: primaryScreen.frame.maxY - displayFrame.maxY, width: displayFrame.width, height: displayFrame.height)
        let accessibilityElements = await Task.detached(priority: .userInitiated) {
            AccessibilityElementReader.elements(intersecting: displayFrameCG, maximum: 80)
        }.value
        guard !accessibilityElements.isEmpty else { return (ocrElements, [:]) }

        let pixelsPerPoint = CGFloat(capture.cgImage.width) / max(displayFrame.width, 1)
        var merged = Array(ocrElements.prefix(100))
        var byID: [Int: AccessibilityElement] = [:]
        var nextID = (ocrElements.map(\.id).max() ?? 0) + 1
        for accessibilityElement in accessibilityElements {
            let frameCG = accessibilityElement.frameInGlobalCGPoints
            let box = CGRect(x: (frameCG.minX - displayFrameCG.minX) * pixelsPerPoint, y: (frameCG.minY - displayFrameCG.minY) * pixelsPerPoint,
                             width: frameCG.width * pixelsPerPoint, height: frameCG.height * pixelsPerPoint)
            if accessibilityElement.shortRole == "text" {
                // Skip static text OCR already has (same words, overlapping box).
                let duplicate = ocrElements.contains { ocr in
                    ocr.boundingBoxInCapturePixels.intersects(box) && ocr.text.lowercased().contains(accessibilityElement.label.lowercased().prefix(20))
                }
                if duplicate { continue }
            }
            let element = ScreenElement(id: nextID, kind: "ax:" + accessibilityElement.shortRole, text: accessibilityElement.label,
                                        boundingBoxInCapturePixels: box, confidence: 1)
            merged.append(element)
            byID[nextID] = accessibilityElement
            nextID += 1
            if merged.count >= 160 { break }
        }
        return (merged, byID)
    }

    /// Capture + OCR started the moment the hotkey is released, so it runs while
    /// the audio is still being transcribed instead of after.
    private var pendingScreenAnalysisTask: Task<ScreenAnalysis, Error>?

    /// The currently running interaction, if any. Cancelled when the user speaks again.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var serviceHealthTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Drawings are anchored to pixels, not content. Scrolling or switching apps
    /// moves the content out from under them, so both dismiss the drawings.
    private var scrollDismissMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var lastScrollDismissAt = Date.distantPast
    /// Scheduled hide for transient cursor mode — cancelled if the user speaks again.
    private var transientHideTask: Task<Void, Never>?

    /// How long drawings stay on screen after the buddy finishes talking.
    private static let drawingAutoClearSeconds: TimeInterval = 45

    init() {
        let workerBaseURL = SounderConfiguration.workerBaseURL
        if SounderConfiguration.chatProvider == "fireworks" {
            self.chatClient = FireworksChatClient(workerBaseURL: workerBaseURL, model: SounderConfiguration.chatModel)
        } else {
            self.chatClient = ClaudeChatClient(workerBaseURL: workerBaseURL, model: SounderConfiguration.chatModel)
        }
        self.analysisClient = AnalysisServiceClient(baseURL: SounderConfiguration.analysisServiceBaseURL)
        self.jevDecisionClient = JevDecisionClient(workerBaseURL: workerBaseURL)

        switch SounderConfiguration.speechOutputProvider {
        case "elevenlabs":
            let elevenLabsClient = ElevenLabsTTSClient(proxyURL: "\(workerBaseURL)/tts")
            self.speechOutput = elevenLabsClient
        case "system":
            self.speechOutput = SystemSpeechOutputClient()
        default:
            let kokoroClient = KokoroTTSClient(ttsBaseURL: SounderConfiguration.ttsServiceBaseURL)
            self.speechOutput = kokoroClient
        }

        self.generalModePipeline = GeneralModePipeline(chatClient: chatClient)
        self.clinicalModePipeline = ClinicalModePipeline(clinicalClient: ClinicalServiceClient(baseURL: SounderConfiguration.analysisServiceBaseURL), chatClient: chatClient)
        self.agentModePipeline = AgentModePipeline(chatClient: chatClient)
        self.researchAgent = ResearchAgent(workerBaseURL: workerBaseURL)
        self.whiteboardPipeline = WhiteboardPipeline(chatClient: chatClient)
        self.translatePipeline = TranslatePipeline(chatClient: chatClient)
        self.readabilityPipeline = ReadabilityPipeline(chatClient: chatClient)

        let offlineVoiceEnabled = UserDefaults.standard.object(forKey: "sounderOfflineVoiceEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "sounderOfflineVoiceEnabled")
        let transcriptionProvider: any BuddyTranscriptionProvider = offlineVoiceEnabled
            ? AppleSpeechTranscriptionProvider()
            : BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.buddyDictationManager = BuddyDictationManager(transcriptionProvider: transcriptionProvider)
            startSpeakingPoll()
}

    /// True when all four required permissions are granted.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    // MARK: - Settings

    func setSelectedMode(_ mode: SounderMode) {
        selectedMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "sounderSelectedMode_v3")
    }

    func setClipboardFallbackEnabled(_ isEnabled: Bool) {
        isClipboardFallbackEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "sounderClipboardFallbackEnabled")
    }

    /// Push-to-talk chord. Stored on BuddyPushToTalkShortcut (read by the event tap
    /// on every event) and mirrored here so the settings UI can observe it.
    @Published private(set) var pushToTalkChord: PushToTalkChord = BuddyPushToTalkShortcut.currentChord
    @Published private(set) var isRecordingHotkey = false
    private var hotkeyRecordingTimeoutTask: Task<Void, Never>?

    func setPushToTalkChord(_ chord: PushToTalkChord) {
        guard chord.isValid else { return }
        BuddyPushToTalkShortcut.currentChord = chord
        pushToTalkChord = chord
        print("⌨️ push-to-talk chord → \(chord.displayText)")
    }

    func setPushToTalkShortcut(_ shortcutOption: BuddyPushToTalkShortcut.ShortcutOption) {
        setPushToTalkChord(shortcutOption.chord)
    }

    /// Records the next chord the user presses (modifiers, optionally plus one key).
    /// Esc or ten seconds of nothing cancels.
    func beginRecordingHotkey() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        hotkeyRecordingTimeoutTask?.cancel()
        hotkeyRecordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.globalPushToTalkShortcutMonitor.cancelRecordingChord()
        }
        globalPushToTalkShortcutMonitor.beginRecordingChord { [weak self] chord in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hotkeyRecordingTimeoutTask?.cancel()
                self.isRecordingHotkey = false
                if let chord { self.setPushToTalkChord(chord) } else { print("⌨️ hotkey recording cancelled") }
            }
        }
    }

    func cancelRecordingHotkey() {
        globalPushToTalkShortcutMonitor.cancelRecordingChord()
    }

    /// Whether spoken answers are also shown as a caption beside the buddy.
    @Published private(set) var isCaptionEnabled: Bool = UserDefaults.standard.object(forKey: "sounderCaptionEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "sounderCaptionEnabled")

    func setCaptionEnabled(_ isEnabled: Bool) {
        isCaptionEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "sounderCaptionEnabled")
        if !isEnabled { clearCaption() }
    }

    var chatModelDisplayName: String {
        SounderConfiguration.chatModel ?? SounderConfiguration.chatProvider
    }

    /// Screen rewind: keep the last 15 minutes of low-res frames in memory.
    @Published private(set) var isScreenRewindEnabled: Bool = UserDefaults.standard.object(forKey: "octoScreenRewindEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "octoScreenRewindEnabled")

    func setScreenRewindEnabled(_ isEnabled: Bool) {
        isScreenRewindEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "octoScreenRewindEnabled")
        updateScreenRewindRecorder()
        if !isEnabled { rewindPanelManager.hide() }
    }

    private func updateScreenRewindRecorder() {
        screenHistoryRecorder.setEnabled(isScreenRewindEnabled && hasScreenRecordingPermission && hasCompletedOnboarding)
    }

    /// Dwell to ask: hold the hotkey still over something for a second, no speech needed.
    @Published private(set) var isDwellEnabled: Bool = UserDefaults.standard.object(forKey: "octoDwellEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "octoDwellEnabled")

    func setDwellEnabled(_ isEnabled: Bool) {
        isDwellEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "octoDwellEnabled")
    }

    /// Agent rehearsal: act the plan out with a ghost cursor and wait for "go" before doing it.
    @Published private(set) var isAgentRehearsalEnabled: Bool = UserDefaults.standard.object(forKey: "octoAgentRehearsalEnabled") == nil
        ? false
        : UserDefaults.standard.bool(forKey: "octoAgentRehearsalEnabled")

    /// "rehearse …", "show me the plan first", "dry run …" ask for a rehearsal on this task only.
    private static func rehearsalRequested(in transcript: String) -> (wanted: Bool, task: String) {
        let lowered = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["rehearse ", "dry run ", "show me the plan for ", "show me the plan to ", "plan first ", "plan out ", "walk me through before you "]
        for prefix in prefixes where lowered.hasPrefix(prefix) {
            return (true, String(transcript.dropFirst(prefix.count)))
        }
        let suffixes = [" but rehearse first", " but show me the plan first", " show me the plan first", " rehearse first", " plan first"]
        for suffix in suffixes where lowered.hasSuffix(suffix) {
            return (true, String(transcript.dropLast(suffix.count)))
        }
        return (false, transcript)
    }

    func setAgentRehearsalEnabled(_ isEnabled: Bool) {
        isAgentRehearsalEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "octoAgentRehearsalEnabled")
    }

    func setOfflineVoiceEnabled(_ isEnabled: Bool) {
        isOfflineVoiceEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "sounderOfflineVoiceEnabled")
        let provider: any BuddyTranscriptionProvider = isEnabled
            ? AppleSpeechTranscriptionProvider()
            : BuddyTranscriptionProviderFactory.makeDefaultProvider()
        buddyDictationManager.replaceTranscriptionProvider(provider)
    }

    /// User preference for whether the cursor buddy should be shown all the time.
    /// When off, the overlay appears only for the duration of an interaction.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has pressed Start at least once. Persisted.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - Lifecycle

    func start() {
        refreshAllPermissions()
        print("🔑 Octo start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        startServiceHealthPolling()
        #if DEBUG
        startTypedQuestionWatcher()
        #endif
        // Vision's first text request loads models (several seconds). Pay it now, off-main.
        Task.detached(priority: .utility) {
            let startedAt = Date()
            ScreenTextRecognizer.warmUp()
            print("👁️ Vision OCR warmed up in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        }
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        installDrawingDismissMonitors()

        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// First "Start" press: show the overlay with the welcome bubble and say hello.
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true
        ClickyAnalytics.trackOnboardingStarted()

        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true

        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            try? await speechOutput.speakText("hey, i'm octo. open a spreadsheet, hold control and option, and ask me what's weird or what drives a column.")
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        screenChangeWatcher.stop()
        speechOutput.stopPlayback()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        serviceHealthTimer?.invalidate()
        serviceHealthTimer = nil
        if let scrollDismissMonitor { NSEvent.removeMonitor(scrollDismissMonitor) }
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
    }

    // MARK: - Permissions

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()
        updateScreenRewindRecorder()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy screenshot
    /// capture. Once the user approves, we persist the grant.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    isRequestingScreenContent = false
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                isRequestingScreenContent = false
                guard didCapture else { return }
                hasScreenContentPermission = true
                UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                    overlayWindowManager.hasShownOverlayBefore = true
                    overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                    isOverlayVisible = true
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                isRequestingScreenContent = false
            }
        }
    }

    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    /// Polls the analysis service and the Worker so the panel can show whether
    /// the demo is fully wired before anyone presses the hotkey.
    /// Runs a command as if it had been spoken (quick-action buttons in the card).
    func askByText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, currentResponseTask == nil else { return }
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        mediaCardPanelManager.hide()
        rewindPanelManager.hide()
        whiteboardPanelManager.hide()
        agentTaskCardPanelManager.hide()
        endGuidedRoute()
        drawingLayerModel.clear()
        lastTranscript = trimmed
        pendingScreenAnalysisTask = makeScreenAnalysisTask()
        runInteraction(transcript: trimmed)
    }

    #if DEBUG
    /// Dev hook: a typed question dropped at ~/Library/Logs/Sounder/ask.txt runs as if spoken.
    private var typedQuestionTimer: Timer?
    private func startTypedQuestionWatcher() {
        let askFileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Sounder/ask.txt")
        typedQuestionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentResponseTask == nil, let data = try? Data(contentsOf: askFileURL), let question = String(data: data, encoding: .utf8) else { return }
                do { try FileManager.default.removeItem(at: askFileURL) } catch { print("⌨️ could not remove ask.txt: \(error.localizedDescription)") }
                var trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, self.currentResponseTask == nil else { return }
                // Optional first line "roi: x y w h" in top-left screen points stands in for a circle gesture.
                if trimmed.lowercased().hasPrefix("roi:"), let newline = trimmed.firstIndex(of: "\n") {
                    let numbers = trimmed[..<newline].dropFirst(4).split(separator: " ").compactMap { Double($0) }
                    if numbers.count == 4, let screen = NSScreen.main {
                        self.pendingGestureBoundsGlobal = CGRect(x: numbers[0], y: screen.frame.maxY - numbers[1] - numbers[3], width: numbers[2], height: numbers[3])
                    }
                    trimmed = String(trimmed[trimmed.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                print("⌨️ typed question: \(trimmed)\(self.pendingGestureBoundsGlobal.map { " roi \($0.integral)" } ?? "")")
                self.mediaCardPanelManager.hide()
                self.rewindPanelManager.hide()
                self.whiteboardPanelManager.hide()
                self.agentTaskCardPanelManager.hide()
                self.endGuidedRoute()
                self.drawingLayerModel.clear()
                self.lastTranscript = trimmed
                self.pendingScreenAnalysisTask = self.makeScreenAnalysisTask()
                self.runInteraction(transcript: trimmed)
            }
        }
    }
    #endif

    private func startServiceHealthPolling() {
        refreshServiceHealth()
        serviceHealthTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshServiceHealth()
            }
        }
    }

    func refreshServiceHealth() {
        Task {
            isAnalysisServiceReachable = await analysisClient.checkHealth()
            let health = await Self.probeWorkerHealth()
            isWorkerReachable = health.isReachable
            isJevConfigured = health.isJevConfigured
            jevDecisionClient.isConfigured = health.isJevConfigured
        }
    }

    private static func probeWorkerHealth() async -> (isReachable: Bool, isJevConfigured: Bool) {
        guard let url = URL(string: "\(SounderConfiguration.workerBaseURL)/health") else { return (false, false) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else { return (false, false) }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (true, (payload?["jevConfigured"] as? Bool) ?? false)
    }

    // MARK: - Bindings

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the response pipeline manages that state.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            transientHideTask?.cancel()
            transientHideTask = nil

            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // A new question cancels the previous answer, its speech, its drawings
            // and any pending edit-and-re-run watch.
            currentResponseTask?.cancel()
            currentResponseTask = nil
            speechOutput.stopPlayback()
            screenChangeWatcher.stop()
            drawingLayerModel.clear()
            clearDetectedElementLocation()
            clearCaption()
            mediaCardPanelManager.hide()
            rewindPanelManager.hide()
            whiteboardPanelManager.hide()
            endGuidedRoute()
            dwellFallbackTask?.cancel()
            dwellFallbackTask = nil
            holdStartedAt = Date()
            pendingDwellPointGlobal = nil
            dwellAnchorPointGlobal = nil
            dwellAnchorStartedAt = nil

            ClickyAnalytics.trackPushToTalkStarted()
            beginGestureSampling()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        self?.lastTranscriptReceivedAt = Date()
                        self?.dwellFallbackTask?.cancel()
                        self?.dwellFallbackTask = nil
                        print("🗣️ Octo received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.runInteraction(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            endGestureSampling()
            // Read the screen now, in parallel with transcription.
            if buddyDictationManager.isDictationInProgress {
                pendingScreenAnalysisTask?.cancel()
                pendingScreenAnalysisTask = makeScreenAnalysisTask()
            }
            scheduleDwellFallbackIfNeeded()
        case .none:
            break
        }
    }

    // MARK: - Interaction pipeline (the mode router)

    private func runInteraction(transcript: String, isDwellInteraction: Bool = false) {
        currentResponseTask?.cancel()
        speechOutput.stopPlayback()
        screenChangeWatcher.stop()

        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            await self.performInteraction(transcript: transcript, isRerunAfterEdit: false, isDwellInteraction: isDwellInteraction)
            if !Task.isCancelled {
                self.currentResponseTask = nil
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }
        }
    }

    private func performInteraction(transcript: String, isRerunAfterEdit: Bool, isDwellInteraction: Bool = false) async {
        let interactionStartedAt = Date()
        voiceState = .processing
        screenHistoryRecorder.isPaused = true
        defer { screenHistoryRecorder.isPaused = false }
        var report = SounderInteractionReport(transcript: transcript, modeUsed: "—")
        userContextForCurrentInteraction = userContextStore.promptBundle()
        if let bundle = userContextForCurrentInteraction {
            print("📎 context in prompt: \(userContextStore.items.count) items, \(bundle.images.count) images")
        }

        // Clear our own drawings a frame before capturing so nothing we drew can be read back.
        drawingLayerModel.clearImmediately()
        try? await Task.sleep(nanoseconds: 30_000_000)

        do {
            // 1 + 2. Capture and OCR. Usually already running since the hotkey was
            // released; a re-run after an edit always reads the screen fresh.
            let screenAnalysisTask: Task<ScreenAnalysis, Error>
            if !isRerunAfterEdit, let pendingTask = pendingScreenAnalysisTask {
                screenAnalysisTask = pendingTask
            } else {
                screenAnalysisTask = makeScreenAnalysisTask(isRerunAfterEdit: isRerunAfterEdit)
            }
            pendingScreenAnalysisTask = nil
            let screenAnalysis = try await screenAnalysisTask.value
            try Task.checkCancellation()

            let capture = screenAnalysis.capture
            let textLines = screenAnalysis.textLines
            let elements = screenAnalysis.elements
            report.captureSeconds = screenAnalysis.captureSeconds
            report.ocrSeconds = screenAnalysis.ocrSeconds
            print("👁️ \(textLines.count) OCR lines, \(elements.count) elements")

            // 3. Route. A dwell (hotkey held still, nothing said) always explains what
            // is under the cursor.
            if isDwellInteraction {
                try await runGeneralMode(transcript: transcript, capture: capture, elements: elements, textLines: textLines, regionOfInterest: regionOfInterestForDwell(screenAnalysis),
                                         report: &report, regionReason: "the user held the hotkey with the cursor resting on this spot and said nothing; explain what is under the cursor in one or two sentences.")
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // Questions about the past ("what did that error say five minutes ago?")
            // are answered from the local screen history, in every mode.
            if let rewindRequest = RewindIntent.detect(transcript) {
                try await runRewind(request: rewindRequest, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // A rehearsed plan is waiting: "go", a redirect, or cancel.
            if let rehearsal = pendingRehearsal {
                try await resolveRehearsal(rehearsal, transcript: transcript, screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // Read-aloud session commands ("skip this section", "explain that", "stop").
            if readAloudScript != nil, let command = ReadAloudIntent.command(whileReading: transcript) {
                try await handleReadAloudCommand(command, screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }
            if readAloudScript != nil { endReadAloud() } // anything else ends the reading

            // Jev picks the feature in one typed question. Confident answers route
            // here; anything else falls through to the phrase matchers below.
            if try await routeWithJev(transcript: transcript, screenAnalysis: screenAnalysis, report: &report) {
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            if ReadAloudIntent.startRequested(transcript) {
                try await startReadAloud(screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }
            if ReadableIntent.matches(transcript) {
                try await runMakeReadable(screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }
            if screenAnalysis.regionOfInterestInCapturePixels != nil, let rewriteRequest = RewriteIntent.detect(transcript) {
                try await runRewrite(request: rewriteRequest, screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // Camera as context: something held up to the webcam.
            if let cameraRequest = CameraIntent.detect(transcript, hasRegion: screenAnalysis.regionOfInterestInCapturePixels != nil) {
                try await runCamera(request: cameraRequest, transcript: transcript, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // "read me this dialog": the focused window through the accessibility tree.
            if DialogReaderIntent.matches(transcript) {
                try await runDialogReader(screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // Translate in place: the circled lines, or every foreign line on screen.
            if let translateRequest = TranslateIntent.detect(transcript) {
                try await runTranslate(request: translateRequest, screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // Circle + a short command: type into it, do arithmetic on it, or copy it out.
            let circledRegion = screenAnalysis.regionOfInterestInCapturePixels
            if circledRegion != nil, let dictatedText = DictateIntent.text(from: transcript) {
                try await runDictate(text: dictatedText, screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }
            if circledRegion != nil, let mathRequest = InkMathIntent.detect(transcript) {
                try await runInkMath(request: mathRequest, screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }
            if let extractRequest = ExtractIntent.detect(transcript, hasRegion: circledRegion != nil) {
                try await runExtract(request: extractRequest, screenAnalysis: screenAnalysis, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // "show me a paper / picture / video of…" works in every mode and is
            // checked before "pull up" or "find" can read as an Agent task.
            if let mediaRequest = ResearchAgent.mediaRequest(in: transcript) {
                try await runMediaLookup(request: mediaRequest, textLines: textLines, report: &report)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            // Tasks next ("open spotify and play…"), then Rx, then General.
            let shouldRunAgentMode = selectedMode == .agent
                || (selectedMode == .automatic && AgentModePipeline.looksLikeTask(transcript))
            let rehearsalRequest = Self.rehearsalRequested(in: transcript)
            if shouldRunAgentMode || rehearsalRequest.wanted {
                if isAgentRehearsalEnabled || rehearsalRequest.wanted {
                    try await rehearseAgentTask(task: rehearsalRequest.task, redirect: nil, previousNotes: nil, screenAnalysis: screenAnalysis, report: &report)
                } else {
                    try await runAgentMode(task: transcript, firstScreenAnalysis: screenAnalysis, report: &report)
                }
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }



            // 3. Route. Rx first: a chart with medications plus a clinical question.
            let regionOfInterest = screenAnalysis.regionOfInterestInCapturePixels
            let clinicalReading = ClinicalModePipeline.scoped(screenAnalysis.clinicalReading, to: regionOfInterest)
            let clinicalIntent = ClinicalModePipeline.intent(for: transcript)
            let shouldTryClinicalMode = selectedMode == .clinical
                || (selectedMode == .automatic && clinicalIntent != .none && !clinicalReading.isEmpty)
            if shouldTryClinicalMode {
                try await runClinicalMode(intent: clinicalIntent, reading: clinicalReading, capture: capture, regionOfInterest: regionOfInterest, report: &report, isRerunAfterEdit: isRerunAfterEdit)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            try await runGeneralMode(transcript: transcript, capture: capture, elements: elements, textLines: textLines, regionOfInterest: regionOfInterest, report: &report)
            finishReport(&report, startedAt: interactionStartedAt)
        } catch is CancellationError {
            // User spoke again — interaction was interrupted.
        } catch {
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            print("⚠️ Octo interaction error: \(error)")
            report.errorMessage = error.localizedDescription
            finishReport(&report, startedAt: interactionStartedAt)
            try? await speak(Self.spokenErrorMessage(for: error))
        }
    }

    // MARK: - Screen rewind

    private func runRewind(request: RewindRequest, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Rewind"
        report.analysisTask = "rewind"
        guard isScreenRewindEnabled else {
            try await speak("screen rewind is off. turn it on in settings and i'll start remembering.")
            return
        }
        guard let match = screenHistoryRecorder.search(query: request.query, targetAge: request.targetAgeSeconds) else {
            let remembered = screenHistoryRecorder.oldestFrameAge.map { ScreenHistoryFrame.describeAge($0) } ?? "nothing yet"
            try await speak("i don't have that. i've only been watching since \(remembered).")
            return
        }
        let ageText = ScreenHistoryFrame.describeAge(match.frame.age())
        report.metricText = "frame \(ageText) · \(match.matchedLineIndices.count) lines · \(screenHistoryRecorder.frames.count) frames"
        print("⏪ rewind: \"\(request.query)\" target \(request.targetAgeSeconds.map { "\(Int($0))s" } ?? "any") → \(ageText), score \(String(format: "%.2f", match.score))")

        let query = request.query
        let recorder = screenHistoryRecorder
        rewindPanelManager.show(match: match, frames: recorder.frames, query: query,
                                lineIndicesForFrame: { frame in recorder.lineIndicesMatching(query: query, in: frame) },
                                nearGlobalPoint: NSEvent.mouseLocation)

        // Speak an answer grounded in that frame's text. The matched lines are the
        // fallback, so the answer is never worse than reading them back.
        let matchedLines = match.matchedLineIndices.map { match.frame.lines[$0].text }
        var spokenText = matchedLines.isEmpty
            ? "here's what was on screen \(ageText). i've highlighted the frame."
            : "\(ageText) it said: \(matchedLines.prefix(2).joined(separator: ". "))"
        let frameText = String(match.frame.text.prefix(3500))
        let systemPrompt = "you're octo. the user asked about something that was on their screen earlier. answer from the screen text below only, in one or two spoken sentences, lowercase, quoting the exact relevant line when there is one. start with how long ago it was. never invent text that is not in the frame."
        let userText = "this frame is from \(ageText).\nmatched lines: \(matchedLines.isEmpty ? "(none)" : matchedLines.joined(separator: " | "))\n\nfull screen text:\n\(frameText)\n\nuser asked: \"\(report.transcript)\""
        if let answer = try? await chatClient.completeText(systemPrompt: systemPrompt, userText: userText, maxTokens: 500, timeoutSeconds: 15, effort: "low"),
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spokenText = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try Task.checkCancellation()
        try await speak(spokenText)
    }

    // MARK: - Dwell (hold still to ask)

    /// Tracks whether the cursor rested in one spot while the hotkey was held.
    private func noteCursorForDwell(_ location: CGPoint, now: Date) {
        if let anchor = dwellAnchorPointGlobal, hypot(location.x - anchor.x, location.y - anchor.y) <= Self.dwellRadiusInPoints {
            if let startedAt = dwellAnchorStartedAt, now.timeIntervalSince(startedAt) >= Self.dwellSeconds {
                pendingDwellPointGlobal = anchor
            }
        } else {
            dwellAnchorPointGlobal = location
            dwellAnchorStartedAt = now
        }
    }

    /// After a release with a dwell, waits briefly for a transcript; if none comes,
    /// explains what was under the cursor.
    private func scheduleDwellFallbackIfNeeded() {
        guard isDwellEnabled, let dwellPoint = pendingDwellPointGlobal else { return }
        let releasedAt = Date()
        dwellFallbackTask?.cancel()
        dwellFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.lastTranscriptReceivedAt < releasedAt, self.currentResponseTask == nil else { return }
            print("👁️ dwell: nothing said, explaining what's under the cursor at \(Int(dwellPoint.x)),\(Int(dwellPoint.y))")
            self.pendingDwellPointGlobal = dwellPoint
            self.pendingScreenAnalysisTask?.cancel()
            self.pendingScreenAnalysisTask = nil
            self.runInteraction(transcript: "what is this?", isDwellInteraction: true)
        }
    }

    /// A box around the dwell point, in capture pixels, so General mode looks there.
    private func regionOfInterestForDwell(_ screenAnalysis: ScreenAnalysis) -> CGRect? {
        guard let dwellPoint = pendingDwellPointGlobal else { return nil }
        pendingDwellPointGlobal = nil
        let displayFrame = screenAnalysis.capture.geometry.displayFrame
        let boxInPoints = CGRect(x: dwellPoint.x - 180, y: dwellPoint.y - 110, width: 360, height: 220)
        let localRect = CGRect(x: boxInPoints.minX - displayFrame.minX, y: displayFrame.maxY - boxInPoints.maxY, width: boxInPoints.width, height: boxInPoints.height)
        let fullBounds = CGRect(x: 0, y: 0, width: screenAnalysis.capture.cgImage.width, height: screenAnalysis.capture.cgImage.height)
        let region = screenAnalysis.capture.geometry.capturePixelRect(fromDisplayPointRect: localRect).intersection(fullBounds)
        return region.isNull || region.isEmpty ? nil : region
    }

    // MARK: - Whiteboard

    private func showWhiteboard(_ diagram: WhiteboardDiagram, elements: [ScreenElement], geometry: CaptureGeometry) {
        guard let screen = NSScreen.screens.first(where: { $0.frame == geometry.displayFrame }) ?? NSScreen.main else { return }
        // Where the screen's text lives, in global AppKit coords; the sketch goes beside it.
        var occupied: CGRect?
        for element in elements {
            let box = element.boundingBoxInCapturePixels
            let bottomLeft = geometry.globalAppKitPoint(fromCapturePixel: CGPoint(x: box.minX, y: box.maxY))
            let topRight = geometry.globalAppKitPoint(fromCapturePixel: CGPoint(x: box.maxX, y: box.minY))
            let rect = CGRect(x: bottomLeft.x, y: bottomLeft.y, width: topRight.x - bottomLeft.x, height: topRight.y - bottomLeft.y)
            occupied = occupied.map { $0.union(rect) } ?? rect
        }
        whiteboardPanelManager.show(diagram, avoiding: occupied ?? screen.visibleFrame.insetBy(dx: 200, dy: 120), on: screen)
    }

    // MARK: - Guided path

    private func globalRect(forCapturePixelRect box: CGRect, geometry: CaptureGeometry) -> CGRect {
        let bottomLeft = geometry.globalAppKitPoint(fromCapturePixel: CGPoint(x: box.minX, y: box.maxY))
        let topRight = geometry.globalAppKitPoint(fromCapturePixel: CGPoint(x: box.maxX, y: box.minY))
        return CGRect(x: bottomLeft.x, y: bottomLeft.y, width: topRight.x - bottomLeft.x, height: topRight.y - bottomLeft.y)
    }

    // MARK: - Jev intent routing

    /// Asks Jev which feature the request is for and runs it. Returns false when
    /// Jev is unavailable, unsure, or the words lack a parameter the feature needs
    /// (a language, an export format, the text to type), so the phrase matchers
    /// decide as before. Mode pins still win: Agent and Rx only run where the
    /// mode picker allows them.
    private func routeWithJev(transcript: String, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws -> Bool {
        let circledRegion = screenAnalysis.regionOfInterestInCapturePixels
        let clinicalReading = ClinicalModePipeline.scoped(screenAnalysis.clinicalReading, to: circledRegion)
        guard let decision = await JevIntentRouter.route(
            transcript: transcript, hasCircledRegion: circledRegion != nil,
            frontmostAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
            hasClinicalReading: !clinicalReading.isEmpty, isReadingAloud: false, using: jevDecisionClient
        ), decision.confidence >= JevIntentRouter.confidenceThreshold else { return false }

        switch decision.intent {
        case .rewind:
            guard let request = RewindIntent.detect(transcript) else { return false }
            try await runRewind(request: request, report: &report)
        case .readAloud:
            try await startReadAloud(screenAnalysis: screenAnalysis, report: &report)
        case .makeReadable:
            try await runMakeReadable(screenAnalysis: screenAnalysis, report: &report)
        case .rewrite:
            guard circledRegion != nil else { return false }
            let request = RewriteIntent.detect(transcript) ?? RewriteRequest(instruction: "rewrite it to be clearer and better written, keeping the meaning")
            try await runRewrite(request: request, screenAnalysis: screenAnalysis, report: &report)
        case .camera:
            let request = CameraIntent.detect(transcript, hasRegion: circledRegion != nil) ?? .look
            try await runCamera(request: request, transcript: transcript, report: &report)
        case .dialogReader:
            try await runDialogReader(screenAnalysis: screenAnalysis, report: &report)
        case .translate:
            let request = TranslateIntent.detect(transcript) ?? TranslateRequest(targetLanguageName: "english", targetLanguage: .english)
            try await runTranslate(request: request, screenAnalysis: screenAnalysis, report: &report)
        case .dictate:
            guard circledRegion != nil, let dictatedText = DictateIntent.text(from: transcript) else { return false }
            try await runDictate(text: dictatedText, screenAnalysis: screenAnalysis, report: &report)
        case .inkMath:
            guard circledRegion != nil, let request = InkMathIntent.detect(transcript) else { return false }
            try await runInkMath(request: request, screenAnalysis: screenAnalysis, report: &report)
        case .extract:
            let request = ExtractIntent.detect(transcript, hasRegion: circledRegion != nil) ?? ExtractRequest(format: .csv)
            try await runExtract(request: request, screenAnalysis: screenAnalysis, report: &report)
        case .media:
            guard let request = ResearchAgent.mediaRequest(in: transcript) else { return false }
            try await runMediaLookup(request: request, textLines: screenAnalysis.textLines, report: &report)
        case .agentTask:
            guard selectedMode == .automatic || selectedMode == .agent else { return false }
            let rehearsalRequest = Self.rehearsalRequested(in: transcript)
            if isAgentRehearsalEnabled || rehearsalRequest.wanted {
                try await rehearseAgentTask(task: rehearsalRequest.task, redirect: nil, previousNotes: nil, screenAnalysis: screenAnalysis, report: &report)
            } else {
                try await runAgentMode(task: transcript, firstScreenAnalysis: screenAnalysis, report: &report)
            }
        case .clinical:
            guard selectedMode == .automatic || selectedMode == .clinical, !clinicalReading.isEmpty else { return false }
            try await runClinicalMode(intent: ClinicalModePipeline.intent(for: transcript), reading: clinicalReading, capture: screenAnalysis.capture,
                                      regionOfInterest: circledRegion, report: &report, isRerunAfterEdit: false)
        case .general:
            guard selectedMode == .automatic || selectedMode == .general else { return false }
            try await runGeneralMode(transcript: transcript, capture: screenAnalysis.capture, elements: screenAnalysis.elements, textLines: screenAnalysis.textLines,
                                     regionOfInterest: circledRegion, report: &report)
        }
        return true
    }

    private func startGuidedRoute(elements: [ScreenElement], labels: [String], geometry: CaptureGeometry) {
        endGuidedRoute()
        guidedRouteElements = elements
        guidedRouteLabels = labels
        guidedRouteGeometry = geometry
        guidedRouteStep = 0
        redrawGuidedRoute()
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.guidedRouteDidClick(at: NSEvent.mouseLocation) }
        }
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: handler) {
            guidedRouteClickMonitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { event in handler(event); return event }) {
            guidedRouteClickMonitors.append(localMonitor)
        }
        print("🧭 guide: \(elements.count) steps, waiting for step 1")
    }

    private func redrawGuidedRoute() {
        guard let geometry = guidedRouteGeometry else { return }
        let primitives = DrawingOpsBuilder.route(through: guidedRouteElements, labels: guidedRouteLabels, currentStep: guidedRouteStep)
        drawingLayerModel.show(primitives, geometry: geometry, autoClearAfterSeconds: 180)
    }

    private func guidedRouteDidClick(at globalPoint: CGPoint) {
        guard let geometry = guidedRouteGeometry, guidedRouteStep < guidedRouteElements.count else { return }
        let target = globalRect(forCapturePixelRect: guidedRouteElements[guidedRouteStep].boundingBoxInCapturePixels, geometry: geometry).insetBy(dx: -14, dy: -10)
        guard target.contains(globalPoint) else { return }
        guidedRouteStep += 1
        print("🧭 guide: step \(guidedRouteStep) of \(guidedRouteElements.count) done")
        if guidedRouteStep >= guidedRouteElements.count {
            let finished = DrawingOpsBuilder.route(through: guidedRouteElements, labels: guidedRouteLabels, currentStep: guidedRouteElements.count)
            drawingLayerModel.show(finished, geometry: geometry, autoClearAfterSeconds: 4)
            endGuidedRoute(keepDrawing: true)
            presentCaption("that's all the steps.")
        } else {
            // Give the click a moment to land before repainting over the new state.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.redrawGuidedRoute()
            }
        }
    }

    private func endGuidedRoute(keepDrawing: Bool = false) {
        for monitor in guidedRouteClickMonitors { NSEvent.removeMonitor(monitor) }
        guidedRouteClickMonitors = []
        guidedRouteElements = []
        guidedRouteLabels = []
        guidedRouteGeometry = nil
        guidedRouteStep = 0
    }

    // MARK: - Read this to me

    /// The circled region's lines, or, with no circle, the lines inside the frontmost
    /// window (so a second window or the notch card is not read into the text).
    private func linesForReading(_ screenAnalysis: ScreenAnalysis) -> [RecognizedTextLine] {
        if let region = screenAnalysis.regionOfInterestInCapturePixels {
            return screenAnalysis.textLines.filter { $0.boundingBoxInCapturePixels.intersects(region) }
        }
        if let windowRect = focusedWindowRectInCapturePixels(capture: screenAnalysis.capture) {
            let inside = screenAnalysis.textLines.filter { windowRect.insetBy(dx: 4, dy: 4).contains($0.boundingBoxInCapturePixels) }
            if inside.count >= 3 { return inside }
        }
        return screenAnalysis.textLines
    }

    private func focusedWindowRectInCapturePixels(capture: SounderScreenCapture) -> CGRect? {
        guard let frameCG = AccessibilityElementReader.focusedWindowFrameCG(), let primaryScreen = NSScreen.screens.first else { return nil }
        let displayFrame = capture.geometry.displayFrame
        let displayFrameCG = CGRect(x: displayFrame.minX, y: primaryScreen.frame.maxY - displayFrame.maxY, width: displayFrame.width, height: displayFrame.height)
        let pixelsPerPoint = CGFloat(capture.cgImage.width) / max(displayFrame.width, 1)
        return CGRect(x: (frameCG.minX - displayFrameCG.minX) * pixelsPerPoint, y: (frameCG.minY - displayFrameCG.minY) * pixelsPerPoint,
                      width: frameCG.width * pixelsPerPoint, height: frameCG.height * pixelsPerPoint)
    }

    /// Speech clients return once playback has begun; reading aloud needs the end.
    /// Mirrors the speech clients' playback into `isSpeaking` for the notch.
    private func startSpeakingPoll() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                let playing = self.speechOutput.isPlaying || self.fallbackSpeechOutput.isPlaying
                if playing != self.isSpeaking { self.isSpeaking = playing }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func waitForSpeechToFinish(maximumSeconds: TimeInterval = 90) async {
        let deadline = Date().addingTimeInterval(maximumSeconds)
        // Give the queue a beat to start before checking.
        try? await Task.sleep(nanoseconds: 120_000_000)
        while speechOutput.isPlaying, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func startReadAloud(screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Read aloud"
        report.analysisTask = "read-aloud"
        let script = ReadAloudScript.build(from: linesForReading(screenAnalysis))
        gesturePathPointsGlobal = []
        guard !script.sentences.isEmpty else {
            try await speak("i don't see anything to read here.")
            return
        }
        readAloudScript = script
        readAloudIndex = 0
        readAloudGeometry = screenAnalysis.capture.geometry
        report.metricText = "\(script.sentences.count) sentences · \(script.paragraphCount) paragraphs"
        print("📖 read aloud: \(script.sentences.count) sentences in \(script.paragraphCount) paragraphs")
        try await speak("reading. hold the key and say skip, explain that, or stop.")
        try await readAloudLoop()
    }

    /// Speaks sentence by sentence, lighting the lines of the one being read.
    private func readAloudLoop() async throws {
        guard let script = readAloudScript, let geometry = readAloudGeometry else { return }
        isReadingAloud = true
        defer { isReadingAloud = false }
        while readAloudIndex < script.sentences.count {
            try Task.checkCancellation()
            let sentence = script.sentences[readAloudIndex]
            let rects = sentence.lineIndices.map { script.lines[$0].boundingBoxInCapturePixels }
            var primitives: [DrawingPrimitive] = rects.enumerated().map { index, rect in
                .highlight(id: "read-\(readAloudIndex)-\(index)", rectInCapturePixels: rect.insetBy(dx: -3, dy: -2), color: .yellow)
            }
            if let first = rects.first {
                primitives.append(.marginBar(id: "read-bar-\(readAloudIndex)", rectInCapturePixels: first, color: .green))
            }
            drawingLayerModel.show(primitives, geometry: geometry)
            try await speak(sentence.text)
            await waitForSpeechToFinish()
            try Task.checkCancellation()
            readAloudIndex += 1
        }
        print("📖 finished \(script.sentences.count) sentences")
        drawingLayerModel.clear()
        try await speak("that's the end of what's on screen. scroll down and say continue if there's more.")
    }

    private func handleReadAloudCommand(_ command: ReadAloudIntent.Command, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Read aloud"
        guard let script = readAloudScript else { return }
        switch command {
        case .start:
            try await startReadAloud(screenAnalysis: screenAnalysis, report: &report)
        case .stop:
            endReadAloud()
            report.analysisTask = "read-stop"
            try await speak("okay.")
        case .skipSection:
            let currentParagraph = readAloudIndex < script.sentences.count ? script.sentences[readAloudIndex].paragraphIndex : script.paragraphCount
            if let next = script.sentences.firstIndex(where: { $0.paragraphIndex > currentParagraph }) {
                readAloudIndex = next
                report.analysisTask = "read-skip"
                try await readAloudLoop()
            } else {
                endReadAloud()
                try await speak("that was the last section on screen.")
            }
        case .back:
            readAloudIndex = max(0, readAloudIndex - 1)
            report.analysisTask = "read-back"
            try await readAloudLoop()
        case .resume:
            report.analysisTask = "read-resume"
            if readAloudIndex >= script.sentences.count {
                // Finished the visible text: read whatever is on screen now (the user scrolled).
                try await startReadAloud(screenAnalysis: screenAnalysis, report: &report)
            } else {
                try await readAloudLoop()
            }
        case .explain:
            report.analysisTask = "read-explain"
            let index = min(readAloudIndex, script.sentences.count - 1)
            let sentence = script.sentences[index]
            let question = "explain this sentence from what i'm reading, briefly: \"\(sentence.text)\""
            let rects = sentence.lineIndices.map { script.lines[$0].boundingBoxInCapturePixels }
            let region = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
            try await runGeneralMode(transcript: question, capture: screenAnalysis.capture, elements: screenAnalysis.elements, textLines: screenAnalysis.textLines,
                                     regionOfInterest: region.isEmpty ? nil : region.insetBy(dx: -40, dy: -40), report: &report,
                                     regionReason: "the user is having this text read aloud and asked to explain the highlighted sentence")
            try Task.checkCancellation()
            try await readAloudLoop()
        }
    }

    private func endReadAloud() {
        readAloudScript = nil
        readAloudIndex = 0
        readAloudGeometry = nil
        isReadingAloud = false
    }

    // MARK: - Make this readable

    private func runMakeReadable(screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Readable"
        report.analysisTask = "readable"
        let lines = Array(linesForReading(screenAnalysis)
            .sorted { $0.boundingBoxInCapturePixels.minY < $1.boundingBoxInCapturePixels.minY }
            .filter { $0.text.count >= 3 }
            .prefix(120))
        gesturePathPointsGlobal = []
        guard lines.count >= 4 else {
            try await speak("there isn't enough text here to structure.")
            return
        }
        presentCaption("reading the page…")
        let startedAt = Date()
        let structure = try await readabilityPipeline.structure(for: lines.map(\.text))
        report.planSeconds = Date().timeIntervalSince(startedAt)
        try Task.checkCancellation()

        var primitives = regionOutlinePrimitives(screenAnalysis.regionOfInterestInCapturePixels)
        for index in structure.headingLineIndices {
            let box = lines[index].boundingBoxInCapturePixels
            primitives.append(.marginBar(id: "heading-\(index)", rectInCapturePixels: box, color: .green))
            primitives.append(.underline(id: "heading-line-\(index)", rectInCapturePixels: box, color: .green))
        }
        for index in structure.keyPointLineIndices where !structure.headingLineIndices.contains(index) {
            primitives.append(.highlight(id: "key-\(index)", rectInCapturePixels: lines[index].boundingBoxInCapturePixels.insetBy(dx: -3, dy: -2), color: .yellow))
        }
        for (position, definition) in structure.definitions.enumerated() {
            let box = lines[definition.lineIndex].boundingBoxInCapturePixels
            primitives.append(.badge(id: "def-\(position)", anchorInCapturePixels: CGPoint(x: box.maxX + 2, y: box.midY), text: "\(definition.term): \(definition.definition)"))
        }
        drawingLayerModel.show(primitives, geometry: screenAnalysis.capture.geometry, autoClearAfterSeconds: 150)
        report.metricText = "\(structure.headingLineIndices.count) headings · \(structure.keyPointLineIndices.count) key points · \(structure.definitions.count) definitions"
        print("📑 readable: \(report.metricText ?? "")")
        try await speak(structure.summary.isEmpty ? "i've marked the headings and key points." : structure.summary)
    }

    // MARK: - Fix this paragraph

    private func runRewrite(request: RewriteRequest, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Rewrite"
        report.analysisTask = "rewrite"
        guard let region = screenAnalysis.regionOfInterestInCapturePixels else { return }
        let lines = screenAnalysis.textLines
            .filter { $0.boundingBoxInCapturePixels.intersects(region) }
            .sorted { $0.boundingBoxInCapturePixels.minY < $1.boundingBoxInCapturePixels.minY }
        gesturePathPointsGlobal = []
        guard !lines.isEmpty else {
            try await speak("i don't see text in what you circled.")
            return
        }
        var paragraph = ""
        for line in lines {
            var text = line.text.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("-"), text.count > 2 { text.removeLast() } else { text += " " }
            paragraph += text
        }
        paragraph = paragraph.trimmingCharacters(in: .whitespaces)
        presentCaption("rewriting…")
        let startedAt = Date()
        let result = try await readabilityPipeline.rewrite(paragraph, instruction: request.instruction)
        report.planSeconds = Date().timeIntervalSince(startedAt)
        try Task.checkCancellation()
        guard !result.rewritten.isEmpty else {
            try await speak("i couldn't come up with a better version.")
            return
        }

        let block = lines.dropFirst().reduce(lines[0].boundingBoxInCapturePixels) { $0.union($1.boundingBoxInCapturePixels) }
        let heights = lines.map(\.boundingBoxInCapturePixels.height).sorted()
        let background = BackgroundColorSampler.sample(screenAnalysis.capture.cgImage, around: block)
        let segments = result.segments.map { TextBlockSegment(text: $0.text, isChanged: $0.isChanged) }
        let primitives: [DrawingPrimitive] = [
            .textBlock(id: "rewrite", rectInCapturePixels: block, segments: segments, lineHeightInCapturePixels: heights[heights.count / 2],
                       backgroundRed: background.red, backgroundGreen: background.green, backgroundBlue: background.blue, usesDarkText: background.luminance > 0.55)
        ]
        drawingLayerModel.show(primitives, geometry: screenAnalysis.capture.geometry, autoClearAfterSeconds: 120)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.rewritten, forType: .string)
        let changedCount = result.segments.filter(\.isChanged).count
        report.metricText = "\(changedCount) changes · \(result.rewritten.count) chars"
        print("✍️ rewrite (\(request.instruction)): \(changedCount) changed spans")
        try await speak("here's the rewrite, changes are marked, and it's on your clipboard. \(result.summary)")
    }

    // MARK: - Camera as context

    private func runCamera(request: CameraIntent.Request, transcript: String, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Camera"
        report.analysisTask = "camera"
        if request == .close {
            cameraContextPanelManager.hide()
            try await speak("camera's off.")
            return
        }
        presentCaption("looking through the camera…")
        guard await cameraContextPanelManager.show() else {
            try await speak("i can't use the camera. check camera access for octo in system settings.")
            return
        }
        // A beat for exposure, then the newest frame.
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let frame = await cameraContextPanelManager.captureFrame() else {
            try await speak("i'm not getting a picture from the camera.")
            return
        }
        cameraContextPanelManager.setStatus("reading…")
        let ocrStartedAt = Date()
        let lines = try await Task.detached(priority: .userInitiated) {
            try ScreenTextRecognizer.recognizeText(in: frame, recognitionLevel: .accurate, maximumWidth: 1600)
        }.value
        report.ocrSeconds = Date().timeIntervalSince(ocrStartedAt)
        try Task.checkCancellation()
        let orderedLines = lines.sorted { $0.boundingBoxInCapturePixels.minY < $1.boundingBoxInCapturePixels.minY }
        cameraContextPanelManager.showRecognizedLines(orderedLines, frameSize: CGSize(width: frame.width, height: frame.height), status: "\(orderedLines.count) lines")
        print("📷 camera frame \(frame.width)×\(frame.height): \(orderedLines.count) lines")

        guard let jpeg = NativeScreenCaptureUtility.makeDownscaledJPEG(from: frame, maximumWidth: 1280, compressionQuality: 0.8) else {
            try await speak("i couldn't read the frame.")
            return
        }
        let answerStartedAt = Date()
        let answer = try await generalModePipeline.answerAboutCameraFrame(transcript: transcript, frameJPEG: jpeg.data, textLines: orderedLines.map(\.text), userContext: userContextForCurrentInteraction)
        report.planSeconds = Date().timeIntervalSince(answerStartedAt)
        try Task.checkCancellation()
        // Keep just the lines the answer used lit on the preview.
        if !answer.keyLineIndices.isEmpty {
            cameraContextPanelManager.showRecognizedLines(answer.keyLineIndices.map { orderedLines[$0] }, frameSize: CGSize(width: frame.width, height: frame.height), status: "\(orderedLines.count) lines")
        }
        // What the camera saw stays in the conversation as pinned context.
        let cameraText = orderedLines.map(\.text).joined(separator: "\n")
        if cameraText.count >= 12 {
            userContextStore.addText("from the camera:\n" + String(cameraText.prefix(1500)))
        }
        conversationHistory.append(ChatModelPriorTurn(userText: transcript, assistantText: answer.spokenText))
        report.metricText = "\(orderedLines.count) lines · \(frame.width)×\(frame.height)"
        cameraContextPanelManager.scheduleHide(afterSeconds: 60)
        try await speak(answer.spokenText)
    }

    // MARK: - Read me this dialog (accessibility)

    private func runDialogReader(screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Read"
        report.analysisTask = "read-dialog"
        let summary = await Task.detached(priority: .userInitiated) { AccessibilityElementReader.focusedWindowSummary() }.value
        guard let summary, !(summary.texts.isEmpty && summary.buttons.isEmpty) else {
            // No accessibility tree (web canvas, game): fall back to reading the OCR lines.
            let lines = screenAnalysis.textLines.prefix(12).map(\.text)
            try await speak(lines.isEmpty ? "i can't find anything readable in the front window." : "the window says: " + lines.joined(separator: ". "))
            return
        }
        // Highlight what is being read, in order.
        let capture = screenAnalysis.capture
        let displayFrame = capture.geometry.displayFrame
        if let primaryScreen = NSScreen.screens.first {
            let displayFrameCG = CGRect(x: displayFrame.minX, y: primaryScreen.frame.maxY - displayFrame.maxY, width: displayFrame.width, height: displayFrame.height)
            let pixelsPerPoint = CGFloat(capture.cgImage.width) / max(displayFrame.width, 1)
            let rects = summary.elements.prefix(30).map { element -> CGRect in
                let frame = element.frameInGlobalCGPoints
                return CGRect(x: (frame.minX - displayFrameCG.minX) * pixelsPerPoint, y: (frame.minY - displayFrameCG.minY) * pixelsPerPoint,
                              width: frame.width * pixelsPerPoint, height: frame.height * pixelsPerPoint)
            }
            drawingLayerModel.show(DrawingOpsBuilder.highlightCells(rects: rects), geometry: capture.geometry, autoClearAfterSeconds: 25)
        }
        var spoken = "\(summary.title). "
        let texts = summary.texts.prefix(14).joined(separator: ". ")
        if !texts.isEmpty { spoken += texts + ". " }
        if !summary.buttons.isEmpty { spoken += "buttons: " + summary.buttons.prefix(8).joined(separator: ", ") + "." }
        report.metricText = "\(summary.texts.count) texts · \(summary.buttons.count) controls"
        print("♿️ read dialog: \(summary.title) · \(summary.texts.count) texts · \(summary.buttons.count) controls")
        try await speak(spoken)
    }

    // MARK: - Translate in place

    private func runTranslate(request: TranslateRequest, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Translate"
        report.analysisTask = "translate-\(request.targetLanguageName)"
        let capture = screenAnalysis.capture
        let region = screenAnalysis.regionOfInterestInCapturePixels
        let scopedLines = linesForReading(screenAnalysis)
        let candidates = Array(TranslateIntent.candidateLines(scopedLines, target: request.targetLanguage, isScoped: region != nil).prefix(120))
        gesturePathPointsGlobal = []
        guard !candidates.isEmpty else {
            try await speak(region == nil ? "everything on screen already looks like \(request.targetLanguageName). circle what you want translated." : "i don't see text to translate in there.")
            return
        }
        presentCaption("translating \(candidates.count) lines…")
        let translateStartedAt = Date()
        let translations = try await translatePipeline.translate(lines: candidates.map(\.text), to: request.targetLanguageName)
        report.planSeconds = Date().timeIntervalSince(translateStartedAt)
        try Task.checkCancellation()

        let cgImage = capture.cgImage
        var primitives: [DrawingPrimitive] = regionOutlinePrimitives(region)
        for (index, line) in candidates.enumerated() {
            guard let translated = translations[index], !translated.isEmpty else { continue }
            let box = line.boundingBoxInCapturePixels
            let background = BackgroundColorSampler.sample(cgImage, around: box)
            primitives.append(.textPatch(id: "translate-\(index)", rectInCapturePixels: box, text: translated,
                                         backgroundRed: background.red, backgroundGreen: background.green, backgroundBlue: background.blue,
                                         usesDarkText: background.luminance > 0.55))
        }
        drawingLayerModel.show(primitives, geometry: capture.geometry, autoClearAfterSeconds: 90)
        report.metricText = "\(translations.count) of \(candidates.count) lines → \(request.targetLanguageName)"
        print("🌐 translate: \(translations.count)/\(candidates.count) lines → \(request.targetLanguageName)")
        let spokenText = translations.count <= 2
            ? translations.keys.sorted().compactMap { translations[$0] }.joined(separator: ". ")
            : "translated \(translations.count) lines into \(request.targetLanguageName). it's painted over the original."
        try await speak(spokenText)
    }

    // MARK: - Lasso to extract

    private func runExtract(request: ExtractRequest, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Extract"
        report.analysisTask = "extract-\(request.format.rawValue)"
        let capture = screenAnalysis.capture
        let region = screenAnalysis.regionOfInterestInCapturePixels
        let lines = screenAnalysis.textLines.filter { line in
            guard let region else { return true }
            return line.boundingBoxInCapturePixels.intersects(region)
        }
        guard !lines.isEmpty else {
            try await speak("i don't see any text in there.")
            return
        }
        gesturePathPointsGlobal = []

        var clipboardText: String
        var primitives: [DrawingPrimitive] = regionOutlinePrimitives(region)
        var spokenText: String
        let table = request.format == .text ? nil : TableExtractor.extractTable(from: lines, imageSize: capture.pixelSize)
        if let table, table.rowCount >= 1, table.columnCount >= 2, table.extractionConfidence >= 0.4 {
            switch request.format {
            case .json: clipboardText = ExtractIntent.json(headers: table.headers, rows: table.rows)
            case .markdown: clipboardText = ExtractIntent.markdown(headers: table.headers, rows: table.rows)
            case .csv, .text: clipboardText = ExtractIntent.csv(headers: table.headers, rows: table.rows)
            }
            let cellRects = table.rowCellBoxes.flatMap { $0.compactMap { $0 } } + table.headerCellBoxes.compactMap { $0 }
            primitives += DrawingOpsBuilder.highlightCells(rects: cellRects)
            let formatName = request.format == .text ? "csv" : request.format.rawValue
            spokenText = "copied \(table.rowCount) rows and \(table.columnCount) columns as \(formatName). every cell i used is highlighted."
            report.metricText = "\(table.rowCount)×\(table.columnCount) · \(formatName) · \(Int(table.extractionConfidence * 100))%"
        } else if request.format != .text, case let grid = ExtractIntent.grid(from: lines), grid.rows.count >= 2, (grid.rows.first?.count ?? 0) >= 2 {
            // Looser grid from line boxes when the strict extractor is unsure.
            switch request.format {
            case .json: clipboardText = ExtractIntent.json(headers: grid.headers, rows: grid.rows)
            case .markdown: clipboardText = ExtractIntent.markdown(headers: grid.headers, rows: grid.rows)
            case .csv, .text: clipboardText = ExtractIntent.csv(headers: grid.headers, rows: grid.rows)
            }
            primitives += DrawingOpsBuilder.highlightCells(rects: lines.map(\.boundingBoxInCapturePixels))
            let columnCount = grid.rows.first?.count ?? 0
            spokenText = "copied \(grid.rows.count) rows and \(columnCount) columns as \(request.format.rawValue). every cell i used is highlighted."
            report.metricText = "\(grid.rows.count)×\(columnCount) · \(request.format.rawValue) · grid"
        } else {
            let orderedLines = lines.sorted { $0.boundingBoxInCapturePixels.minY < $1.boundingBoxInCapturePixels.minY }
            let texts = orderedLines.map(\.text)
            clipboardText = request.format == .json
                ? (String(data: (try? JSONSerialization.data(withJSONObject: texts, options: [.prettyPrinted])) ?? Data(), encoding: .utf8) ?? texts.joined(separator: "\n"))
                : texts.joined(separator: "\n")
            primitives += DrawingOpsBuilder.highlightCells(rects: orderedLines.map(\.boundingBoxInCapturePixels))
            spokenText = "copied \(texts.count) lines of text."
            report.metricText = "\(texts.count) lines · text"
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardText, forType: .string)
        print("📋 extract: \(clipboardText.count) chars → clipboard (\(request.format.rawValue))")
        drawingLayerModel.show(primitives, geometry: capture.geometry, autoClearAfterSeconds: 20)
        try await speak(spokenText)
    }

    // MARK: - Ink math (spoken)

    private func runInkMath(request: InkMathRequest, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Math"
        report.analysisTask = "math"
        let capture = screenAnalysis.capture
        guard let region = screenAnalysis.regionOfInterestInCapturePixels else { return }
        let lines = screenAnalysis.textLines
            .filter { $0.boundingBoxInCapturePixels.intersects(region) }
            .sorted { $0.boundingBoxInCapturePixels.minY < $1.boundingBoxInCapturePixels.minY }
        var values: [Double] = []
        var usedLines: [RecognizedTextLine] = []
        var prefix = "", suffix = "", hadDecimals = false
        for line in lines {
            let found = InkMathIntent.numbers(in: line.text)
            guard !found.isEmpty else { continue }
            usedLines.append(line)
            for number in found {
                if values.isEmpty { prefix = number.prefix; suffix = number.suffix }
                if number.value != number.value.rounded() { hadDecimals = true }
                values.append(number.value)
            }
        }
        gesturePathPointsGlobal = []
        guard !values.isEmpty, let result = InkMathIntent.apply(request.operation, to: values) else {
            try await speak("i don't see a number in what you circled.")
            return
        }
        let resultText = prefix + InkMathIntent.format(result, decimals: hadDecimals || result != result.rounded() ? 2 : 0) + suffix
        let firstLine = usedLines[0].boundingBoxInCapturePixels
        var primitives = regionOutlinePrimitives(region) + DrawingOpsBuilder.highlightCells(rects: usedLines.map(\.boundingBoxInCapturePixels))
        primitives.append(.badge(id: "math-result", anchorInCapturePixels: CGPoint(x: firstLine.maxX + 4, y: firstLine.midY), text: "= \(resultText)"))
        drawingLayerModel.show(primitives, geometry: capture.geometry, autoClearAfterSeconds: 30)

        let spokenText: String
        switch request.operation {
        case .sum, .average, .maximum, .minimum:
            spokenText = "\(request.spokenOperation) of those \(values.count) numbers is \(resultText)."
        default:
            spokenText = "\(prefix)\(InkMathIntent.format(values[0]))\(suffix) \(request.spokenOperation) is \(resultText)."
        }
        report.metricText = "\(values.count) numbers → \(resultText)"
        print("🧮 math: \(values) \(request.spokenOperation) → \(resultText)")
        try await speak(spokenText)
    }

    // MARK: - Dictate into a circled field

    private func runDictate(text: String, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Type"
        report.analysisTask = "type"
        guard let region = screenAnalysis.regionOfInterestInCapturePixels else { return }
        let target = screenAnalysis.capture.geometry.globalAppKitPoint(fromCapturePixel: CGPoint(x: region.midX, y: region.midY))
        gesturePathPointsGlobal = []
        drawingLayerModel.show(regionOutlinePrimitives(region), geometry: screenAnalysis.capture.geometry, autoClearAfterSeconds: 6)
        presentCaption("typing…")
        MacControl.click(atGlobalAppKitPoint: target)
        try? await Task.sleep(nanoseconds: 250_000_000)
        MacControl.typeText(text)
        report.metricText = "typed \(text.count) chars"
        print("⌨️ dictate: \"\(text)\" at \(Int(target.x)),\(Int(target.y))")
        try await speak("typed it.")
    }

    /// Looks up one paper, image, video or link with web search and holds the card
    /// up next to the buddy. Screen text goes along as context so "a paper about
    /// this" resolves to what is on screen.
    private func runMediaLookup(
        request: ResearchAgent.MediaRequest,
        textLines: [RecognizedTextLine],
        report: inout SounderInteractionReport
    ) async throws {
        report.modeUsed = "Media"
        report.analysisTask = "media"
        presentCaption("finding that…")
        var screenContext = textLines.prefix(40).map(\.text).joined(separator: " · ")
        if let contextText = userContextForCurrentInteraction?.promptText {
            screenContext = contextText + "\n\nscreen text: " + screenContext
        }
        let lookupStartedAt = Date()
        let card = try await researchAgent.findMedia(query: request.query, preferredKind: request.preferredKind, screenContext: screenContext)
        report.analysisSeconds = Date().timeIntervalSince(lookupStartedAt)
        report.metricText = "media: \(card.kind.rawValue)"
        try Task.checkCancellation()
        mediaCardPanelManager.show(card, nearGlobalPoint: NSEvent.mouseLocation)
        let spokenText: String
        switch card.kind {
        case .paper: spokenText = "here's a paper: \(card.title). click the card to open it."
        case .image: spokenText = "here's a picture. click it to open the full thing."
        case .video: spokenText = "found a video: \(card.title). click to watch."
        case .link: spokenText = "here's a link: \(card.title)."
        }
        try await speak(spokenText)
    }

    // MARK: - Jev checks inside the agent loop

    /// Screen text as Jev sees it: the element list, roles and all, capped.
    private static func screenTextForJev(_ elements: [ScreenElement]) -> String {
        elements.prefix(160).map { "[\($0.kind)] \(String($0.text.prefix(80)))" }.joined(separator: "\n")
    }

    /// Probability that the expected outcome of the last action is visible now.
    private func jevExpectedOutcomeCheck(expected: String, elements: [ScreenElement]) async -> Double? {
        guard jevDecisionClient.isConfigured else { return nil }
        let state = "expected after the last action: \(expected)\n\nscreen text now:\n\(Self.screenTextForJev(elements))"
        return try? await jevDecisionClient.noul(state: state, instructions: "The expected outcome is visible in the screen text.",
                                                 whenTrue: "The screen text shows what was expected.", whenFalse: "The screen text does not show it, or shows something else.", timeoutSeconds: 2)
    }

    /// Probability that the task's claimed result is on screen.
    private func jevOutcomeCheck(task: String, claim: String, elements: [ScreenElement]) async -> Double? {
        guard jevDecisionClient.isConfigured else { return nil }
        let state = "task: \(task)\nclaimed result: \(claim)\n\nscreen text now:\n\(Self.screenTextForJev(elements))"
        return try? await jevDecisionClient.noul(state: state, instructions: "The screen text proves the task is complete as claimed.",
                                                 whenTrue: "The result the task asked for is plainly in the screen text.", whenFalse: "The screen text does not show the result, or shows an earlier step.", timeoutSeconds: 2)
    }

    /// Probability that an action sends, pays, deletes, posts or otherwise cannot be undone.
    private func jevIrreversibility(of action: AgentAction, appName: String?) async -> Double? {
        guard jevDecisionClient.isConfigured, [.click, .doubleClick, .pressKeys].contains(action.kind) else { return nil }
        let state = "app: \(appName ?? "unknown")\naction: \(action.kind.rawValue) \(action.keys ?? "") \(action.text ?? "")\nwhat it does: \(action.narration)\nexpected: \(action.expectedOutcome ?? "")"
        return try? await jevDecisionClient.noul(state: state, instructions: "This action is outward-facing or irreversible.",
                                                 whenTrue: "It sends a message or email, posts publicly, pays, purchases, deletes, or submits a form.", whenFalse: "It only navigates, opens, searches, types into a draft, plays media, or changes a view.", timeoutSeconds: 2)
    }

    private static func agentNotes(research: ResearchNotes?, approvedPlan: [AgentPlanStep]?) -> String? {
        var parts: [String] = []
        if let approvedPlan, !approvedPlan.isEmpty {
            parts.append("follow this plan step by step, adapting only if the screen differs; report the step you are on in plan_step:\n" + approvedPlan.map(\.promptLine).joined(separator: "\n"))
        }
        if let research { parts.append(research.asPromptText) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Agent rehearsal (ghost run)

    /// Plans the task, acts it out with a translucent cursor over the real screen
    /// (each step annotated), then waits for "go", a change, or "cancel".
    private func rehearseAgentTask(task: String, redirect: String?, previousNotes: ResearchNotes?, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        report.modeUsed = "Rehearsal"
        report.analysisTask = "rehearse"
        isActing = true
        defer { isActing = false }
        var researchNotes = previousNotes
        if researchNotes == nil, ResearchAgent.needsResearch(for: task) {
            presentCaption("researching how to do that…")
            researchNotes = try? await researchAgent.research(task: task)
        }
        presentCaption("planning…")
        agentTaskCardPanelManager.show(task: task)
        let planStartedAt = Date()
        let plan = try await agentModePipeline.plan(task: task, researchNotes: researchNotes?.asPromptText, userContextText: userContextForCurrentInteraction?.promptText,
                                                     redirect: redirect, capture: screenAnalysis.capture, elements: screenAnalysis.elements)
        report.planSeconds = Date().timeIntervalSince(planStartedAt)
        try Task.checkCancellation()
        guard !plan.steps.isEmpty else {
            agentTaskCardPanelManager.finish(summary: "couldn't work out a plan", succeeded: false)
            try await speak("i couldn't work out a plan for that.")
            return
        }
        agentTaskCardPanelManager.setPlan(plan.steps.map(\.description))
        agentTaskCardPanelManager.setStatus("rehearsing · say \u{201C}go\u{201D} to run, or tell me what to change")
        print("🎬 rehearsal: \(plan.steps.count) steps\n  " + plan.steps.map(\.promptLine).joined(separator: "\n  "))

        // Numbered route over the steps that target something visible now.
        let elementsByID = Dictionary(uniqueKeysWithValues: screenAnalysis.elements.map { ($0.id, $0) })
        let visibleSteps = plan.steps.compactMap { step -> (AgentPlanStep, ScreenElement)? in
            guard let id = step.elementID, let element = elementsByID[id] else { return nil }
            return (step, element)
        }
        if !visibleSteps.isEmpty {
            let route = DrawingOpsBuilder.route(through: visibleSteps.map(\.1), labels: visibleSteps.dropLast().map { "\($0.0.number) · \($0.0.description)" }, currentStep: nil)
            drawingLayerModel.show(route, geometry: screenAnalysis.capture.geometry, autoClearAfterSeconds: 60)
        }
        gesturePathPointsGlobal = []

        // The ghost walks the plan: to each visible target with a pause, and hovers
        // in place for steps that happen on screens not visible yet.
        let geometry = screenAnalysis.capture.geometry
        var ghostPoint = NSEvent.mouseLocation
        let perStep = max(0.45, min(1.1, 5.0 / Double(plan.steps.count)))
        for step in plan.steps {
            try Task.checkCancellation()
            if let id = step.elementID, let element = elementsByID[id] {
                ghostPoint = geometry.globalAppKitPoint(fromCapturePixel: element.centerInCapturePixels)
            } else {
                ghostPoint = CGPoint(x: ghostPoint.x + 26, y: ghostPoint.y - 22)
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                ghostCursorGlobalPoint = ghostPoint
                ghostStepLabel = "\(step.number) · \(step.description)"
            }
            try? await Task.sleep(nanoseconds: UInt64(perStep * 1_000_000_000))
        }
        ghostStepLabel = "say \u{201C}go\u{201D}, or tell me what to change"
        pendingRehearsal = PendingRehearsal(task: task, steps: plan.steps, researchNotes: researchNotes, screenAnalysis: screenAnalysis)
        report.metricText = "\(plan.steps.count) steps · \(visibleSteps.count) on screen"
        try await speak(plan.spokenSummary + " say go, or tell me what to change.")

        rehearsalTimeoutTask?.cancel()
        rehearsalTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self, self.pendingRehearsal != nil else { return }
            self.clearRehearsal()
            self.presentCaption("plan expired. ask again when you're ready.")
        }
    }

    private func clearRehearsal() {
        agentTaskCardPanelManager.hide()
        rehearsalTimeoutTask?.cancel()
        rehearsalTimeoutTask = nil
        pendingRehearsal = nil
        withAnimation(.easeOut(duration: 0.3)) {
            ghostCursorGlobalPoint = nil
            ghostStepLabel = ""
        }
    }

    private func resolveRehearsal(_ rehearsal: PendingRehearsal, transcript: String, screenAnalysis: ScreenAnalysis, report: inout SounderInteractionReport) async throws {
        let lowered = transcript.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        let goWords = ["go", "yes", "yeah", "yep", "do it", "go ahead", "run it", "okay go", "ok go", "looks good", "that's right", "proceed", "confirm"]
        let cancelWords = ["cancel", "no", "nope", "stop", "never mind", "nevermind", "forget it", "don't", "abort"]
        clearRehearsal()
        if goWords.contains(where: { lowered == $0 || lowered.hasPrefix($0 + " ") }) {
            print("🎬 rehearsal approved")
            try await runAgentMode(task: rehearsal.task, firstScreenAnalysis: screenAnalysis, report: &report, approvedPlan: rehearsal.steps, notes: rehearsal.researchNotes)
        } else if cancelWords.contains(where: { lowered == $0 || lowered.hasPrefix($0 + " ") }) {
            report.modeUsed = "Rehearsal"
            report.analysisTask = "cancelled"
            drawingLayerModel.clear()
            try await speak("okay, dropped it.")
        } else {
            // Anything else is a redirect: re-plan with the instruction and rehearse again.
            print("🎬 rehearsal redirect: \(transcript)")
            drawingLayerModel.clear()
            try await rehearseAgentTask(task: rehearsal.task, redirect: transcript, previousNotes: rehearsal.researchNotes, screenAnalysis: screenAnalysis, report: &report)
        }
    }

    private func runAgentMode(
        task: String,
        firstScreenAnalysis: ScreenAnalysis,
        report: inout SounderInteractionReport,
        approvedPlan: [AgentPlanStep]? = nil,
        notes: ResearchNotes? = nil
    ) async throws {
        report.modeUsed = "Agent"
        agentTaskCardPanelManager.show(task: task)
        var isTaskCardFinished = false
        defer { if !isTaskCardFinished { agentTaskCardPanelManager.finish(summary: "stopped", succeeded: false) } }

        // Unfamiliar app → quick web research first. The plan only feeds the agent's
        // prompt; the user sees a caption, never the sources or the step list.
        var researchNotes: ResearchNotes? = notes
        if researchNotes == nil, ResearchAgent.needsResearch(for: task) {
            presentCaption("researching how to do that…")
            let researchStartedAt = Date()
            researchNotes = try? await researchAgent.research(task: task)
            report.planSeconds += Date().timeIntervalSince(researchStartedAt)
            if let notes = researchNotes, !notes.steps.isEmpty {
                presentCaption("got a plan, \(notes.steps.count) steps…")
            }
        }
        try Task.checkCancellation()

        // The steps on the card: the approved rehearsal plan, or a fresh plan for
        // this run. The same plan guides the step-by-step decisions.
        var plan = approvedPlan ?? []
        if plan.isEmpty {
            presentCaption("planning…")
            let planStartedAt = Date()
            if let planned = try? await agentModePipeline.plan(task: task, researchNotes: researchNotes?.asPromptText, userContextText: userContextForCurrentInteraction?.promptText,
                                                                redirect: nil, capture: firstScreenAnalysis.capture, elements: firstScreenAnalysis.elements) {
                plan = planned.steps
            }
            report.planSeconds += Date().timeIntervalSince(planStartedAt)
            try Task.checkCancellation()
        }
        agentTaskCardPanelManager.setPlan(plan.map(\.description))

        isActing = true
        defer { isActing = false }
        var screenAnalysis = firstScreenAnalysis
        var history: [String] = []
        var completionSummary = "i ran out of steps before finishing that."
        var verificationAttempts = 0
        var previousFingerprint = ScreenHistoryRecorder.signature(of: firstScreenAnalysis.capture.cgImage)
        var lastActionKey = ""
        var repeatCount = 0
        var noChangeStreak = 0
        for stepNumber in 1...AgentModePipeline.maximumSteps {
            try Task.checkCancellation()
            let decisionStartedAt = Date()
            let action = try await agentModePipeline.decideNextAction(
                task: task, researchNotes: Self.agentNotes(research: researchNotes, approvedPlan: plan.isEmpty ? nil : plan), userContextText: userContextForCurrentInteraction?.promptText,
                stepNumber: stepNumber, history: history,
                capture: screenAnalysis.capture, elements: screenAnalysis.elements
            )
            report.planSeconds += Date().timeIntervalSince(decisionStartedAt)
            try Task.checkCancellation()
            print("🤖 step \(stepNumber): \(action.kind.rawValue) \(action.elementID.map { "[\($0)]" } ?? "") \(action.text ?? action.app ?? action.keys ?? "") — \(action.narration)")

            if action.kind == .askUser || action.kind == .cannotDetermine {
                // The way out: no guessing. The question or reason is spoken and the loop ends.
                completionSummary = action.text ?? action.narration
                history.append("\(stepNumber). \(action.kind.rawValue): \(completionSummary)")
                agentTaskCardPanelManager.finish(summary: completionSummary, succeeded: false)
                isTaskCardFinished = true
                break
            }

            if action.kind == .done || action.isTaskComplete {
                // Trust, but verify: a fresh screenshot must show the outcome before
                // the buddy says it is done. Otherwise the verifier's hint goes into
                // the history and the loop continues.
                if verificationAttempts < 2 {
                    verificationAttempts += 1
                    agentTaskCardPanelManager.setStatus("checking the result…")
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    let checkAnalysis = try await makeScreenAnalysisTask().value
                    // Jev reads the fresh screen text first: near-certain either way
                    // skips the slow vision verifier; anything in between goes to Claude.
                    let verdict: AgentVerdict
                    if let quick = await jevOutcomeCheck(task: task, claim: action.completionSummary ?? action.narration, elements: checkAnalysis.elements), quick >= 0.92 || quick <= 0.08 {
                        verdict = AgentVerdict(isAchieved: quick >= 0.92, evidence: quick >= 0.92 ? "the screen text shows it" : "the screen text does not show it yet", nextHint: nil)
                        print("⚡️ jev verdict: \(String(format: "%.2f", quick)) (claude verify skipped)")
                    } else {
                        verdict = try await agentModePipeline.verifyCompletion(task: task, claimedSummary: action.completionSummary ?? action.narration, capture: checkAnalysis.capture, elements: checkAnalysis.elements)
                    }
                    print("🔍 verify: \(verdict.isAchieved ? "achieved" : "NOT achieved") — \(verdict.evidence)")
                    if !verdict.isAchieved, stepNumber < AgentModePipeline.maximumSteps {
                        history.append("\(stepNumber). claimed done, but the screen shows: \(verdict.evidence). next: \(verdict.nextHint ?? "keep going")")
                        presentCaption("not there yet…")
                        agentTaskCardPanelManager.setStatus("not there yet · \(verdict.evidence)")
                        screenAnalysis = checkAnalysis
                        continue
                    }
                    completionSummary = verdict.isAchieved ? (action.completionSummary ?? action.narration) : "i tried, but \(verdict.evidence)"
                    agentTaskCardPanelManager.finish(summary: completionSummary, succeeded: verdict.isAchieved)
                } else {
                    completionSummary = action.completionSummary ?? action.narration
                    agentTaskCardPanelManager.finish(summary: completionSummary, succeeded: true)
                }
                isTaskCardFinished = true
                history.append("done: \(completionSummary)")
                break
            }

            // Brake before anything outward-facing or irreversible: Jev scores the
            // action; a high score means a caption and a pause the hotkey can interrupt.
            if let irreversibility = await jevIrreversibility(of: action, appName: NSWorkspace.shared.frontmostApplication?.localizedName), irreversibility >= 0.8 {
                print("⚡️ jev brake: \(String(format: "%.2f", irreversibility)) for \(action.narration)")
                presentCaption("about to \(action.narration). this can't be undone — press the hotkey to stop me.")
                agentTaskCardPanelManager.setStatus("pausing before an irreversible step…")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                try Task.checkCancellation()
            }

            // The card follows along: the plan step the model says it is on, else the
            // next plan step in order, else a new row for an unplanned action.
            if let planStep = action.planStep, planStep >= 1, planStep <= plan.count {
                agentTaskCardPanelManager.beginStep(at: planStep - 1)
            } else if stepNumber <= plan.count {
                agentTaskCardPanelManager.beginStep(at: stepNumber - 1)
            } else {
                agentTaskCardPanelManager.addStep(action.narration)
            }

            // Show what is about to happen: caption + buddy flies to the target + highlight.
            presentCaption(action.narration + "…")
            let stepPrimitives: [DrawingPrimitive]
            if let elementID = action.elementID, let element = screenAnalysis.elements.first(where: { $0.id == elementID }) {
                voiceState = .idle
                detectedElementBubbleText = action.narration
                detectedElementDisplayFrame = screenAnalysis.capture.geometry.displayFrame
                detectedElementScreenLocation = screenAnalysis.capture.geometry.globalAppKitPoint(fromCapturePixel: element.centerInCapturePixels)
                stepPrimitives = DrawingOpsBuilder.highlightElements([element])
                // Let the flight land before the click so the trail matches the action.
                try? await Task.sleep(nanoseconds: 900_000_000)
                clearDetectedElementLocation()
            } else {
                stepPrimitives = []
            }
            // Only the element highlight is drawn; the step narration goes to the caption.
            if !stepPrimitives.isEmpty {
                drawingLayerModel.show(stepPrimitives, geometry: screenAnalysis.capture.geometry, autoClearAfterSeconds: 30)
            }

            let historyEntry = await agentModePipeline.execute(action, elements: screenAnalysis.elements, accessibilityElementsByID: screenAnalysis.accessibilityElementsByID, geometry: screenAnalysis.capture.geometry)
            history.append("\(stepNumber). \(historyEntry)\(action.expectedOutcome.map { " (expected: \($0))" } ?? "")")
            report.analysisTask = "agent · \(stepNumber) steps"

            try? await Task.sleep(nanoseconds: AgentModePipeline.settleDelayNanoseconds(after: action))
            try Task.checkCancellation()
            // Our own drawings are excluded from capture, but clear anyway so a
            // highlight never overlaps an element the next screenshot needs.
            drawingLayerModel.clearImmediately()
            try? await Task.sleep(nanoseconds: 40_000_000)
            screenAnalysis = try await makeScreenAnalysisTask().value

            // Observe after every action: did the screen change? The answer goes on
            // the history line, and repeats or dead actions trigger a loop breaker.
            let fingerprint = ScreenHistoryRecorder.signature(of: screenAnalysis.capture.cgImage)
            let changed = ScreenHistoryRecorder.meanAbsoluteDifference(fingerprint, previousFingerprint) >= 3
                || ScreenHistoryRecorder.changedCellFraction(fingerprint, previousFingerprint) >= 0.008
            previousFingerprint = fingerprint
            // Jev checks whether the expected outcome is in the new screen text; the
            // history line carries both observations for the next decision.
            var outcomeNote = ""
            if let expected = action.expectedOutcome, let likelihood = await jevExpectedOutcomeCheck(expected: expected, elements: screenAnalysis.elements) {
                outcomeNote = likelihood >= 0.7 ? ", expected outcome visible" : (likelihood <= 0.3 ? ", expected outcome NOT visible" : "")
            }
            if var last = history.popLast() {
                last += (changed ? " → screen changed" : " → no visible change") + outcomeNote
                history.append(last)
            }
            let actionKey = "\(action.kind.rawValue)|\(action.elementID ?? -1)|\(action.text ?? "")|\(action.keys ?? "")|\(action.app ?? "")"
            repeatCount = actionKey == lastActionKey ? repeatCount + 1 : 0
            lastActionKey = actionKey
            noChangeStreak = changed ? 0 : noChangeStreak + 1
            if repeatCount >= 1 || noChangeStreak >= 2 {
                history.append("note: the last actions repeated or had no visible effect. state what you expected to happen and what you observe, then choose a different approach, or ask_user.")
                print("🔁 loop breaker (repeat \(repeatCount), no-change streak \(noChangeStreak))")
                repeatCount = 0
                noChangeStreak = 0
            }
        }

        report.metricText = "\(history.count) actions\(researchNotes == nil ? "" : " · researched")"
        print("🤖 history:\n  " + history.joined(separator: "\n  "))
        drawingLayerModel.clear()
        if !isTaskCardFinished {
            agentTaskCardPanelManager.finish(summary: completionSummary, succeeded: false)
            isTaskCardFinished = true
        }
        try await speak(completionSummary)
    }

    private func runClinicalMode(
        intent: ClinicalIntent,
        reading: ClinicalScreenReading,
        capture: SounderScreenCapture,
        regionOfInterest: CGRect?,
        report: inout SounderInteractionReport,
        isRerunAfterEdit: Bool
    ) async throws {
        report.modeUsed = regionOfInterest == nil ? "Rx" : "Rx (circled)"
        report.tableRowCount = reading.medications.count
        report.tableColumnCount = reading.conditions.count
        report.extractionSource = "ondevice-ner"

        guard !reading.isEmpty else {
            try await speak("i don't see medications or diagnoses on this screen. open a chart and ask again.")
            return
        }

        let resolvedIntent: ClinicalIntent = intent == .none ? .checkMedications : intent
        let outcome: ClinicalModePipeline.Outcome
        let analysisStartedAt = Date()
        switch resolvedIntent {
        case .evidence(let conditionQuery):
            report.analysisTask = "evidence"
            // Circling a single drug and asking "what's new on this?" scopes the evidence to it.
            let circledDrug = (regionOfInterest != nil && reading.medications.count == 1) ? reading.medications[0].name : nil
            outcome = try await clinicalModePipeline.evidence(reading: reading, conditionQuery: conditionQuery, drug: circledDrug)
        case .checkMedications, .none:
            report.analysisTask = "check"
            guard !reading.medications.isEmpty else {
                try await speak("i see diagnoses but no medication list on this screen.")
                return
            }
            outcome = try await clinicalModePipeline.checkMedications(reading: reading, question: report.transcript, isScopedToCircle: regionOfInterest != nil, userContextText: userContextForCurrentInteraction?.promptText)
        }
        report.analysisSeconds = Date().timeIntervalSince(analysisStartedAt)
        report.metricText = outcome.metricText
        try Task.checkCancellation()

        drawingLayerModel.show(outcome.primitives + regionOutlinePrimitives(regionOfInterest), geometry: capture.geometry, autoClearAfterSeconds: 90)
        gesturePathPointsGlobal = []
        if let mediaCard = outcome.mediaCard {
            mediaCardPanelManager.show(mediaCard, nearGlobalPoint: NSEvent.mouseLocation)
        }
        ClickyAnalytics.trackAIResponseReceived(response: outcome.spokenText)
        try await speak(isRerunAfterEdit ? "updated. " + outcome.spokenText : outcome.spokenText)

        // Edit-and-re-run over the medication list region.
        let medicationBoxes = reading.medications.map(\.rowBox)
        if let firstBox = medicationBoxes.first {
            let region = medicationBoxes.dropFirst().reduce(firstBox) { $0.union($1) }.insetBy(dx: -20, dy: -40)
            let rerunTranscript = report.transcript
            screenChangeWatcher.start(regionInCapturePixels: region, geometry: capture.geometry) { [weak self] in
                guard let self, self.currentResponseTask == nil else { return }
                print("🔁 Chart changed — re-running the med check")
                self.currentResponseTask = Task { [weak self] in
                    guard let self else { return }
                    await self.performInteraction(transcript: rerunTranscript, isRerunAfterEdit: true)
                    if !Task.isCancelled {
                        self.currentResponseTask = nil
                        self.voiceState = .idle
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
        }
    }

    private func runGeneralMode(
        transcript: String,
        capture: SounderScreenCapture,
        elements: [ScreenElement],
        textLines: [RecognizedTextLine] = [],
        regionOfInterest: CGRect?,
        report: inout SounderInteractionReport,
        regionReason: String? = nil
    ) async throws {
        report.modeUsed = regionReason != nil ? "General (dwell)" : (regionOfInterest == nil ? "General" : "General (circled)")
        let answerStartedAt = Date()
        let answer = try await generalModePipeline.answer(
            transcript: transcript,
            capture: capture,
            elements: elements,
            textLines: textLines,
            regionOfInterestInCapturePixels: regionOfInterest,
            conversationHistory: conversationHistory,
            userContext: userContextForCurrentInteraction,
            regionReason: regionReason
        )
        report.planSeconds = Date().timeIntervalSince(answerStartedAt)
        try Task.checkCancellation()

        conversationHistory.append(ChatModelPriorTurn(userText: transcript, assistantText: answer.spokenText))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }

        var highlightPrimitives = DrawingOpsBuilder.highlightRects(answer.highlightRects) + regionOutlinePrimitives(regionOfInterest)
        // Sketched explanation: numbered arrows between the elements, in order.
        // A guide keeps its route alive and lights each step as the user clicks it.
        if answer.routeElements.count >= 2 {
            if answer.routeKind == "guide" {
                startGuidedRoute(elements: answer.routeElements, labels: answer.routeLabels, geometry: capture.geometry)
                report.metricText = "guide · \(answer.routeElements.count) steps"
                highlightPrimitives = []
            } else {
                highlightPrimitives = DrawingOpsBuilder.route(through: answer.routeElements, labels: answer.routeLabels, currentStep: nil) + regionOutlinePrimitives(regionOfInterest)
                report.metricText = "flow · \(answer.routeElements.count) hops"
            }
        }
        if !highlightPrimitives.isEmpty {
            drawingLayerModel.show(highlightPrimitives, geometry: capture.geometry, autoClearAfterSeconds: answer.routeElements.count >= 2 ? 75 : 12)
        }
        gesturePathPointsGlobal = []

        // Whiteboard: sketch the concept in the emptiest margin while the answer is spoken.
        var whiteboardTask: Task<WhiteboardDiagram?, Never>?
        if answer.wantsWhiteboard {
            let question = transcript
            let spokenAnswer = answer.spokenText
            whiteboardTask = Task { [whiteboardPipeline] in
                try? await whiteboardPipeline.diagram(for: question, spokenAnswer: spokenAnswer)
            }
        }

        if let pointedElement = answer.pointedElement {
            // Switch to idle BEFORE setting the location so the triangle is visible and can fly.
            voiceState = .idle
            detectedElementBubbleText = answer.pointLabel ?? "right here!"
            detectedElementDisplayFrame = capture.geometry.displayFrame
            detectedElementScreenLocation = capture.geometry.globalAppKitPoint(fromCapturePixel: answer.pointedCenterInCapturePixels ?? pointedElement.centerInCapturePixels)
            ClickyAnalytics.trackElementPointed(elementLabel: answer.pointLabel)
            print("🎯 Pointing at element \(pointedElement.id) \"\(pointedElement.text.prefix(40))\"")
        }

        ClickyAnalytics.trackAIResponseReceived(response: answer.spokenText)
        try await speak(answer.spokenText)

        if let whiteboardTask, let diagram = await whiteboardTask.value {
            try Task.checkCancellation()
            showWhiteboard(diagram, elements: elements, geometry: capture.geometry)
            report.metricText = (report.metricText.map { $0 + " · " } ?? "") + "sketch · \(diagram.nodes.count) boxes"
        }

        // "show me a paper / video / picture of…": look it up and hold the card up.
        if let mediaQuery = answer.mediaQuery {
            presentCaption("finding that…")
            do {
                let card = try await researchAgent.findMedia(query: mediaQuery, preferredKind: answer.mediaKind, screenContext: nil)
                try Task.checkCancellation()
                mediaCardPanelManager.show(card, nearGlobalPoint: NSEvent.mouseLocation)
                report.metricText = "media: \(card.kind.rawValue)"
            } catch {
                print("⚠️ media lookup failed: \(error.localizedDescription)")
            }
        }
    }

    /// Speaks and flips the cursor into the responding state while audio plays.
    /// The same text is shown as a caption beside the buddy, revealed at speaking pace.
    private func speak(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        presentCaption(trimmedText)
        do {
            try await speechOutput.speakText(trimmedText)
            voiceState = .responding
        } catch {
            ClickyAnalytics.trackTTSError(error: error.localizedDescription)
            print("⚠️ Speech output error (\(speechOutput.displayName)): \(error)")
            // Never go silent: fall back to the on-device system voice.
            try? await fallbackSpeechOutput.speakText(trimmedText)
            voiceState = .responding
        }
    }

    private func finishReport(_ report: inout SounderInteractionReport, startedAt: Date) {
        gesturePathPointsGlobal = []
        report.totalSeconds = Date().timeIntervalSince(startedAt)
        report.completedAt = Date()
        lastInteractionReport = report
        recentInteractionReports.insert(report, at: 0)
        if recentInteractionReports.count > 6 { recentInteractionReports.removeLast(recentInteractionReports.count - 6) }
        print("⏱️ \(report.modeUsed) [picker: \(selectedMode.rawValue)]: capture \(String(format: "%.2f", report.captureSeconds))s, ocr \(String(format: "%.2f", report.ocrSeconds))s, plan \(String(format: "%.2f", report.planSeconds))s, analysis \(String(format: "%.2f", report.analysisSeconds))s, total \(String(format: "%.2f", report.totalSeconds))s\(report.metricText.map { " · \($0)" } ?? "")")
    }

    private static func spokenErrorMessage(for error: Error) -> String {
        let description = error.localizedDescription.lowercased()
        if description.contains("could not connect") || description.contains("connection") || description.contains("timed out") {
            return "i couldn't reach my backend. check that the worker and the analysis service are running."
        }
        if description.contains("analysis failed") {
            return "the model couldn't run on this table. \(error.localizedDescription)"
        }
        return "something went wrong on my end. try that once more."
    }

    // MARK: - Drawing dismissal on scroll / app switch

    private func installDrawingDismissMonitors() {
        scrollDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            // Trackpad momentum sends a stream; a small nudge should not wipe the drawings.
            guard abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) > 6 else { return }
            Task { @MainActor [weak self] in self?.dismissDrawingsBecauseContentMoved(reason: "scroll") }
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activated = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard activated != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor [weak self] in self?.dismissDrawingsBecauseContentMoved(reason: "app switch") }
        }
    }

    private func dismissDrawingsBecauseContentMoved(reason: String) {
        // Agent mode redraws every step and issues its own scrolls; leave it alone.
        guard lastInteractionReport?.modeUsed != "Agent" || currentResponseTask == nil else { return }
        guard drawingLayerModel.hasDrawings, Date().timeIntervalSince(lastScrollDismissAt) > 0.5 else { return }
        lastScrollDismissAt = Date()
        print("🧽 Drawings dismissed (\(reason))")
        drawingLayerModel.clear()
        screenChangeWatcher.stop()
    }

    // MARK: - Caption

    private func presentCaption(_ text: String) {
        guard isCaptionEnabled, !isReadingAloud else { return }
        captionRevealTimer?.invalidate()
        captionHideTask?.cancel()
        captionFullText = text
        captionRevealProgress = 0
        captionText = ""

        // Reveal whole words so the bubble grows in readable steps rather than jittering per letter.
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        captionRevealTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / Self.captionRevealTicksPerSecond, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                self.captionRevealProgress += Self.captionWordsPerSecond / Self.captionRevealTicksPerSecond
                let revealedWordCount = min(words.count, Int(self.captionRevealProgress))
                let revealedText = words.prefix(revealedWordCount).joined(separator: " ")
                if revealedText != self.captionText {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.captionText = revealedText
                    }
                }
                if revealedWordCount >= words.count {
                    timer.invalidate()
                    self.scheduleCaptionHide()
                }
            }
        }
    }

    /// Keeps the caption up while the voice is still playing, then fades it.
    private func scheduleCaptionHide() {
        captionHideTask?.cancel()
        captionHideTask = Task { [weak self] in
            while let self, self.speechOutput.isPlaying, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearCaption()
        }
    }

    private func clearCaption() {
        captionRevealTimer?.invalidate()
        captionRevealTimer = nil
        captionHideTask?.cancel()
        captionHideTask = nil
        captionFullText = ""
        withAnimation(.easeOut(duration: 0.25)) {
            captionText = ""
        }
    }

    // MARK: - Spatial context (circle gesture)

    private func beginGestureSampling() {
        gestureSamplingTimer?.invalidate()
        gestureTrailFadeTimer?.invalidate()
        gestureTrailFadeTimer = nil
        gesturePathPointsGlobal = []
        gestureTrailPoints = []
        pendingGestureBoundsGlobal = nil
        gestureSamplingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let location = NSEvent.mouseLocation
                let now = Date()
                self.noteCursorForDwell(location, now: now)
                self.pruneGestureTrail(now: now)
                if let last = self.gesturePathPointsGlobal.last, hypot(location.x - last.x, location.y - last.y) < 1.5 { return }
                self.gesturePathPointsGlobal.append(location)
                self.gestureTrailPoints.append(GestureTrailPoint(position: location, time: now.timeIntervalSinceReferenceDate))
            }
        }
    }

    private func pruneGestureTrail(now: Date) {
        let cutoff = now.timeIntervalSinceReferenceDate - Self.gestureTrailLifetime
        if let firstLive = gestureTrailPoints.firstIndex(where: { $0.time >= cutoff }) {
            if firstLive > 0 { gestureTrailPoints.removeFirst(firstLive) }
        } else if !gestureTrailPoints.isEmpty {
            gestureTrailPoints = []
        }
    }

    /// After release the trail keeps fading on its own until nothing is left.
    private func startGestureTrailFadeOut() {
        gestureTrailFadeTimer?.invalidate()
        gestureTrailFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                self.pruneGestureTrail(now: Date())
                if self.gestureTrailPoints.isEmpty {
                    timer.invalidate()
                    self.gestureTrailFadeTimer = nil
                }
            }
        }
    }

    private func endGestureSampling() {
        gestureSamplingTimer?.invalidate()
        gestureSamplingTimer = nil
        startGestureTrailFadeOut()
        guard gesturePathPointsGlobal.count >= 8 else {
            gesturePathPointsGlobal = []
            pendingGestureBoundsGlobal = nil
            return
        }
        let xs = gesturePathPointsGlobal.map(\.x)
        let ys = gesturePathPointsGlobal.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // A small wiggle while holding the key is not a gesture.
        if bounds.width >= Self.minimumGestureSizeInPoints, bounds.height >= Self.minimumGestureSizeInPoints {
            pendingGestureBoundsGlobal = bounds.insetBy(dx: -6, dy: -6)
        } else {
            gesturePathPointsGlobal = []
            pendingGestureBoundsGlobal = nil
        }
    }

    private func regionOutlinePrimitives(_ regionOfInterest: CGRect?) -> [DrawingPrimitive] {
        guard let regionOfInterest else { return [] }
        return [.circle(id: "region-of-interest", rectInCapturePixels: regionOfInterest, tagNumber: nil, color: .green)]
    }

    // MARK: - Screen analysis

    private func makeScreenAnalysisTask(isRerunAfterEdit: Bool = false) -> Task<ScreenAnalysis, Error> {
        Task { @MainActor in
            let captureStartedAt = Date()
            let capture = try await NativeScreenCaptureUtility.captureDisplayUnderCursor()
            let captureSeconds = Date().timeIntervalSince(captureStartedAt)
            try Task.checkCancellation()

            let ocrStartedAt = Date()
            let cgImage = capture.cgImage
            let textLines = try await Task.detached(priority: .userInitiated) {
                try ScreenTextRecognizer.recognizeText(in: cgImage)
            }.value
            let ocrSeconds = Date().timeIntervalSince(ocrStartedAt)
            try Task.checkCancellation()

            let ocrElements = ScreenElementDetector.makeElements(from: textLines)
            let (elements, accessibilityElementsByID) = await Self.mergeAccessibilityElements(into: ocrElements, capture: capture)
            if !accessibilityElementsByID.isEmpty { print("♿️ \(accessibilityElementsByID.count) accessibility elements merged") }
            let clinicalReading = ClinicalEntityExtractor.extract(from: textLines, lexicon: clinicalLexicon)

            // Region of interest from the circle gesture, in capture pixels.
            var regionOfInterest: CGRect?
            if let gestureBounds = pendingGestureBoundsGlobal {
                let displayFrame = capture.geometry.displayFrame
                let localRect = CGRect(x: gestureBounds.minX - displayFrame.minX, y: displayFrame.maxY - gestureBounds.maxY,
                                       width: gestureBounds.width, height: gestureBounds.height)
                let fullBounds = CGRect(x: 0, y: 0, width: capture.cgImage.width, height: capture.cgImage.height)
                let region = capture.geometry.capturePixelRect(fromDisplayPointRect: localRect).intersection(fullBounds)
                regionOfInterest = region.isNull || region.isEmpty ? nil : region
                pendingGestureBoundsGlobal = nil
                lastRegionOfInterestInCapturePixels = regionOfInterest
                if let regionOfInterest { print("🔵 Circled region: \(regionOfInterest.integral) capture px") }
            } else if isRerunAfterEdit {
                regionOfInterest = lastRegionOfInterestInCapturePixels
            } else {
                lastRegionOfInterestInCapturePixels = nil
            }
            if !clinicalReading.isEmpty {
                print("💊 Chart: \(clinicalReading.medications.count) meds \(clinicalReading.medications.map { "\($0.name) \($0.doseMilligrams.map { "\($0)mg" } ?? "")×\($0.dosesPerDay ?? 0)" }), \(clinicalReading.conditions.count) conditions \(clinicalReading.conditions.map(\.canonicalName)), labs \(clinicalReading.labs.map { "\($0.key)=\($0.value)" }), age \(clinicalReading.ageYears ?? -1) \(clinicalReading.sex ?? "")")
            }
            return ScreenAnalysis(capture: capture, textLines: textLines, elements: elements, accessibilityElementsByID: accessibilityElementsByID,
                                  clinicalReading: clinicalReading, regionOfInterestInCapturePixels: regionOfInterest,
                                  captureSeconds: captureSeconds, ocrSeconds: ocrSeconds)
        }
    }

    // MARK: - Calibration self-test

    /// Draws thin boxes around every OCR'd line for a few seconds. If the boxes sit
    /// on the text, the capture-pixel → overlay-point mapping is right.
    func runOverlayCalibration() {
        guard !isRunningCalibration else { return }
        isRunningCalibration = true
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        Task {
            defer { isRunningCalibration = false }
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                let capture = try await NativeScreenCaptureUtility.captureDisplayUnderCursor()
                let cgImage = capture.cgImage
                let textLines = try await Task.detached(priority: .userInitiated) {
                    try ScreenTextRecognizer.recognizeText(in: cgImage)
                }.value
                let elements = ScreenElementDetector.makeElements(from: textLines, maximumCount: 400)
                let primitives = DrawingOpsBuilder.calibrationOutlines(elements)
                drawingLayerModel.show(primitives, geometry: capture.geometry, autoClearAfterSeconds: 5)
                var report = SounderInteractionReport(transcript: "(calibration)", modeUsed: "Calibration")
                report.totalSeconds = 0
                lastInteractionReport = report
                print("📐 Calibration: \(elements.count) text lines outlined on \(capture.geometry.captureWidthInPixels)×\(capture.geometry.captureHeightInPixels) capture")
            } catch {
                print("⚠️ Calibration failed: \(error)")
            }
        }
    }

    // MARK: - Transient cursor

    /// If the cursor is in transient mode (user toggled "Show Octo" off), waits for
    /// speech and any pointing animation to finish, then fades out the overlay.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while speechOutput.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            drawingLayerModel.clear()
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }
}
