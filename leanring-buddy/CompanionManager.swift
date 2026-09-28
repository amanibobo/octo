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

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
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
    @Published private(set) var lastInteractionReport: SounderInteractionReport?

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
    /// Notes, links and images the user pinned in the notch; folded into every prompt.
    let userContextStore = UserContextStore()
    /// Rolling in-memory buffer of low-res frames + OCR for "what did that say five minutes ago?".
    let screenHistoryRecorder = ScreenHistoryRecorder()
    private let rewindPanelManager = RewindPanelManager()
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
        let elements: [ScreenElement]
        let clinicalReading: ClinicalScreenReading
        let regionOfInterestInCapturePixels: CGRect?
        let captureSeconds: Double
        let ocrSeconds: Double
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

        let offlineVoiceEnabled = UserDefaults.standard.object(forKey: "sounderOfflineVoiceEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "sounderOfflineVoiceEnabled")
        let transcriptionProvider: any BuddyTranscriptionProvider = offlineVoiceEnabled
            ? AppleSpeechTranscriptionProvider()
            : BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.buddyDictationManager = BuddyDictationManager(transcriptionProvider: transcriptionProvider)
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
    @Published private(set) var pushToTalkShortcut: BuddyPushToTalkShortcut.ShortcutOption = BuddyPushToTalkShortcut.currentShortcutOption

    func setPushToTalkShortcut(_ shortcutOption: BuddyPushToTalkShortcut.ShortcutOption) {
        BuddyPushToTalkShortcut.currentShortcutOption = shortcutOption
        pushToTalkShortcut = shortcutOption
        print("⌨️ push-to-talk shortcut → \(shortcutOption.displayText)")
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
            isWorkerReachable = await Self.probeWorkerHealth()
        }
    }

    private static func probeWorkerHealth() async -> Bool {
        guard let url = URL(string: "\(SounderConfiguration.workerBaseURL)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else { return false }
        return (200...299).contains(httpResponse.statusCode)
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
                try await runGeneralMode(transcript: transcript, capture: capture, elements: elements, regionOfInterest: regionOfInterestForDwell(screenAnalysis),
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
            if shouldRunAgentMode {
                try await runAgentMode(task: transcript, firstScreenAnalysis: screenAnalysis, report: &report)
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

            try await runGeneralMode(transcript: transcript, capture: capture, elements: elements, regionOfInterest: regionOfInterest, report: &report)
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
        if let answer = try? await chatClient.completeText(systemPrompt: systemPrompt, userText: userText, maxTokens: 160, timeoutSeconds: 10),
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

    private func runAgentMode(
        task: String,
        firstScreenAnalysis: ScreenAnalysis,
        report: inout SounderInteractionReport
    ) async throws {
        report.modeUsed = "Agent"

        // Unfamiliar app → quick web research first. The plan only feeds the agent's
        // prompt; the user sees a caption, never the sources or the step list.
        var researchNotes: ResearchNotes?
        if ResearchAgent.needsResearch(for: task) {
            presentCaption("researching how to do that…")
            let researchStartedAt = Date()
            researchNotes = try? await researchAgent.research(task: task)
            report.planSeconds += Date().timeIntervalSince(researchStartedAt)
            if let notes = researchNotes, !notes.steps.isEmpty {
                presentCaption("got a plan, \(notes.steps.count) steps…")
            }
        }
        try Task.checkCancellation()

        var screenAnalysis = firstScreenAnalysis
        var history: [String] = []
        var completionSummary = "i ran out of steps before finishing that."
        for stepNumber in 1...AgentModePipeline.maximumSteps {
            try Task.checkCancellation()
            let decisionStartedAt = Date()
            let action = try await agentModePipeline.decideNextAction(
                task: task, researchNotes: researchNotes?.asPromptText, userContextText: userContextForCurrentInteraction?.promptText,
                stepNumber: stepNumber, history: history,
                capture: screenAnalysis.capture, elements: screenAnalysis.elements
            )
            report.planSeconds += Date().timeIntervalSince(decisionStartedAt)
            try Task.checkCancellation()
            print("🤖 step \(stepNumber): \(action.kind.rawValue) \(action.elementID.map { "[\($0)]" } ?? "") \(action.text ?? action.app ?? action.keys ?? "") — \(action.narration)")

            if action.kind == .done || action.isTaskComplete {
                completionSummary = action.completionSummary ?? action.narration
                history.append("done: \(completionSummary)")
                break
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

            let historyEntry = await agentModePipeline.execute(action, elements: screenAnalysis.elements, geometry: screenAnalysis.capture.geometry)
            history.append("\(stepNumber). \(historyEntry)")
            report.analysisTask = "agent · \(stepNumber) steps"

            try? await Task.sleep(nanoseconds: AgentModePipeline.settleDelayNanoseconds(after: action))
            try Task.checkCancellation()
            // Our own drawings are excluded from capture, but clear anyway so a
            // highlight never overlaps an element the next screenshot needs.
            drawingLayerModel.clearImmediately()
            try? await Task.sleep(nanoseconds: 40_000_000)
            screenAnalysis = try await makeScreenAnalysisTask().value
        }

        report.metricText = "\(history.count) actions\(researchNotes == nil ? "" : " · researched")"
        print("🤖 history:\n  " + history.joined(separator: "\n  "))
        drawingLayerModel.clear()
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

        let highlightPrimitives = DrawingOpsBuilder.highlightElements(answer.highlightedElements) + regionOutlinePrimitives(regionOfInterest)
        if !highlightPrimitives.isEmpty {
            drawingLayerModel.show(highlightPrimitives, geometry: capture.geometry, autoClearAfterSeconds: 12)
        }
        gesturePathPointsGlobal = []

        if let pointedElement = answer.pointedElement {
            // Switch to idle BEFORE setting the location so the triangle is visible and can fly.
            voiceState = .idle
            detectedElementBubbleText = answer.pointLabel ?? "right here!"
            detectedElementDisplayFrame = capture.geometry.displayFrame
            detectedElementScreenLocation = capture.geometry.globalAppKitPoint(fromCapturePixel: pointedElement.centerInCapturePixels)
            ClickyAnalytics.trackElementPointed(elementLabel: answer.pointLabel)
            print("🎯 Pointing at element \(pointedElement.id) \"\(pointedElement.text.prefix(40))\"")
        }

        ClickyAnalytics.trackAIResponseReceived(response: answer.spokenText)
        try await speak(answer.spokenText)

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
        lastInteractionReport = report
        print("⏱️ \(report.modeUsed) [picker: \(selectedMode.rawValue)]: capture \(String(format: "%.2f", report.captureSeconds))s, ocr \(String(format: "%.2f", report.ocrSeconds))s, plan \(String(format: "%.2f", report.planSeconds))s, analysis \(String(format: "%.2f", report.analysisSeconds))s, total \(String(format: "%.2f", report.totalSeconds))s")
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
        guard isCaptionEnabled else { return }
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
        gesturePathPointsGlobal = []
        pendingGestureBoundsGlobal = nil
        gestureSamplingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let location = NSEvent.mouseLocation
                self.noteCursorForDwell(location, now: Date())
                if let last = self.gesturePathPointsGlobal.last, hypot(location.x - last.x, location.y - last.y) < 1.5 { return }
                self.gesturePathPointsGlobal.append(location)
            }
        }
    }

    private func endGestureSampling() {
        gestureSamplingTimer?.invalidate()
        gestureSamplingTimer = nil
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

            let elements = ScreenElementDetector.makeElements(from: textLines)
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
            return ScreenAnalysis(capture: capture, textLines: textLines, elements: elements,
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
