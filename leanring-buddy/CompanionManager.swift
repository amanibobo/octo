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

    // MARK: - Sounder state

    /// Operating mode chosen in the panel. Persisted.
    @Published private(set) var selectedMode: SounderMode = SounderMode(rawValue: UserDefaults.standard.string(forKey: "sounderSelectedMode") ?? "") ?? .automatic

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
    @Published private(set) var isRunningCalibration = false

    let buddyDictationManager: BuddyDictationManager
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let drawingLayerModel = DrawingLayerModel()

    private let chatClient: FireworksChatClient
    private let analysisClient: AnalysisServiceClient
    private let speechOutput: any SpeechOutputClient
    /// Used only when the configured speech provider fails (e.g. ElevenLabs credits).
    private lazy var fallbackSpeechOutput: SystemSpeechOutputClient = SystemSpeechOutputClient()
    private let generalModePipeline: GeneralModePipeline
    private let dataModePipeline: DataModePipeline
    private let clinicalModePipeline: ClinicalModePipeline
    private let clinicalLexicon = ClinicalLexicon.load()
    private let screenChangeWatcher = ScreenChangeWatcher()

    var speechOutputDisplayName: String { speechOutput.displayName }

    /// Conversation history for General mode so follow-ups make sense.
    private var conversationHistory: [FireworksChatClient.PriorTurn] = []

    /// The plan of the last Data-mode run, reused when the table is edited and re-run.
    private var lastDataModePlan: DataModePlan?

    /// Everything read off the screen for one interaction.
    private struct ScreenAnalysis {
        let capture: SounderScreenCapture
        let textLines: [RecognizedTextLine]
        let elements: [ScreenElement]
        let table: ExtractedTable?
        let chart: ChartRegion?
        let clinicalReading: ClinicalScreenReading
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
    /// Scheduled hide for transient cursor mode — cancelled if the user speaks again.
    private var transientHideTask: Task<Void, Never>?

    /// How long drawings stay on screen after the buddy finishes talking.
    private static let drawingAutoClearSeconds: TimeInterval = 45
    /// Below this OCR confidence Data mode asks the frontmost app for the table via the clipboard.
    private static let clipboardFallbackConfidenceThreshold = 0.9
    /// In Auto mode a table must reach this confidence before the data planner is consulted.
    private static let automaticModeTableConfidenceThreshold = 0.6

    init() {
        let workerBaseURL = SounderConfiguration.workerBaseURL
        self.chatClient = FireworksChatClient(workerBaseURL: workerBaseURL, model: SounderConfiguration.chatModel)
        self.analysisClient = AnalysisServiceClient(baseURL: SounderConfiguration.analysisServiceBaseURL)

        switch SounderConfiguration.speechOutputProvider {
        case "elevenlabs":
            let elevenLabsClient = ElevenLabsTTSClient(proxyURL: "\(workerBaseURL)/tts")
            elevenLabsClient.prefetch(DataModePipeline.fillerPhrases)
            self.speechOutput = elevenLabsClient
        case "system":
            self.speechOutput = SystemSpeechOutputClient()
        default:
            let kokoroClient = KokoroTTSClient(ttsBaseURL: SounderConfiguration.ttsServiceBaseURL)
            kokoroClient.prefetch(DataModePipeline.fillerPhrases)
            self.speechOutput = kokoroClient
        }

        self.generalModePipeline = GeneralModePipeline(chatClient: chatClient)
        self.dataModePipeline = DataModePipeline(chatClient: chatClient, analysisClient: analysisClient)
        self.clinicalModePipeline = ClinicalModePipeline(clinicalClient: ClinicalServiceClient(baseURL: SounderConfiguration.analysisServiceBaseURL))

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
        UserDefaults.standard.set(mode.rawValue, forKey: "sounderSelectedMode")
    }

    func setClipboardFallbackEnabled(_ isEnabled: Bool) {
        isClipboardFallbackEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "sounderClipboardFallbackEnabled")
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
        print("🔑 Sounder start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
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
            try? await speechOutput.speakText("hey, i'm sounder. open a spreadsheet, hold control and option, and ask me what's weird or what drives a column.")
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

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Sounder received transcript: \(finalTranscript)")
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
            // Read the screen now, in parallel with transcription.
            if buddyDictationManager.isDictationInProgress {
                pendingScreenAnalysisTask?.cancel()
                pendingScreenAnalysisTask = makeScreenAnalysisTask()
            }
        case .none:
            break
        }
    }

    // MARK: - Interaction pipeline (the mode router)

    private func runInteraction(transcript: String) {
        currentResponseTask?.cancel()
        speechOutput.stopPlayback()
        screenChangeWatcher.stop()

        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            await self.performInteraction(transcript: transcript, isRerunAfterEdit: false)
            if !Task.isCancelled {
                self.currentResponseTask = nil
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }
        }
    }

    private func performInteraction(transcript: String, isRerunAfterEdit: Bool) async {
        let interactionStartedAt = Date()
        voiceState = .processing
        var report = SounderInteractionReport(transcript: transcript, modeUsed: "—")

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
                screenAnalysisTask = makeScreenAnalysisTask()
            }
            pendingScreenAnalysisTask = nil
            let screenAnalysis = try await screenAnalysisTask.value
            try Task.checkCancellation()

            let capture = screenAnalysis.capture
            let textLines = screenAnalysis.textLines
            let elements = screenAnalysis.elements
            let extractedTable = screenAnalysis.table
            let chart = screenAnalysis.chart
            report.captureSeconds = screenAnalysis.captureSeconds
            report.ocrSeconds = screenAnalysis.ocrSeconds

            if let extractedTable {
                report.extractionSource = extractedTable.source
                report.extractionConfidence = extractedTable.extractionConfidence
                report.tableRowCount = extractedTable.rowCount
                report.tableColumnCount = extractedTable.columnCount
                // Column names bias the next transcription ("tenure", not "tenor").
                buddyDictationManager.updateContextualKeyterms(extractedTable.headers)
                print("📊 Table: \(extractedTable.rowCount)×\(extractedTable.columnCount), confidence \(String(format: "%.2f", extractedTable.extractionConfidence)), headers \(extractedTable.headers)")
            } else {
                print("📊 No table detected (\(textLines.count) OCR lines)")
            }
            if let chart {
                print("📈 Chart detected at \(chart.boundingBoxInCapturePixels.integral), x ticks \(chart.xTickValues), y ticks \(chart.yTickValues)")
            }

            // 3. Route. Rx first: a chart with medications plus a clinical question.
            let clinicalReading = screenAnalysis.clinicalReading
            let clinicalIntent = ClinicalModePipeline.intent(for: transcript)
            let shouldTryClinicalMode = selectedMode == .clinical
                || (selectedMode == .automatic && clinicalIntent != .none && !clinicalReading.isEmpty)
            if shouldTryClinicalMode {
                try await runClinicalMode(intent: clinicalIntent, reading: clinicalReading, capture: capture, report: &report, isRerunAfterEdit: isRerunAfterEdit)
                finishReport(&report, startedAt: interactionStartedAt)
                return
            }

            let shouldTryDataMode: Bool = {
                switch selectedMode {
                case .general, .clinical: return false
                case .data: return true
                case .automatic:
                    guard let extractedTable else { return false }
                    return Self.isPlausibleDataTable(extractedTable)
                }
            }()

            if shouldTryDataMode {
                guard let table = extractedTable else {
                    report.modeUsed = "Data (no table)"
                    try await speak("i don't see a table on this screen. bring one into view and ask again.")
                    finishReport(&report, startedAt: interactionStartedAt)
                    return
                }

                let planStartedAt = Date()
                let plan: DataModePlan
                if isRerunAfterEdit, let previousPlan = lastDataModePlan {
                    plan = previousPlan
                } else {
                    // Keyword routing is instant; the language model is consulted only
                    // when the user forced Data mode and keywords found nothing.
                    plan = await dataModePipeline.plan(
                        transcript: transcript,
                        table: table,
                        hasChart: chart != nil,
                        allowLanguageModelFallback: selectedMode == .data
                    )
                }
                report.planSeconds = Date().timeIntervalSince(planStartedAt)
                try Task.checkCancellation()

                if plan.task != nil {
                    lastDataModePlan = plan
                    try await runDataMode(plan: plan, table: table, chart: chart, capture: capture, report: &report, isRerunAfterEdit: isRerunAfterEdit)
                    finishReport(&report, startedAt: interactionStartedAt)
                    return
                }

                if selectedMode == .data {
                    report.modeUsed = "Data (not a data question)"
                    try await speak("ask me what's weird, what drives a column, or to fit a trend, and i'll run a model on this table.")
                    finishReport(&report, startedAt: interactionStartedAt)
                    return
                }
                // Auto mode: the planner said this is not a data question → General.
            }

            try await runGeneralMode(transcript: transcript, capture: capture, elements: elements, report: &report)
            finishReport(&report, startedAt: interactionStartedAt)
        } catch is CancellationError {
            // User spoke again — interaction was interrupted.
        } catch {
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            print("⚠️ Sounder interaction error: \(error)")
            report.errorMessage = error.localizedDescription
            finishReport(&report, startedAt: interactionStartedAt)
            try? await speak(Self.spokenErrorMessage(for: error))
        }
    }

    private func runDataMode(
        plan: DataModePlan,
        table extractedTable: ExtractedTable,
        chart: ChartRegion?,
        capture: SounderScreenCapture,
        report: inout SounderInteractionReport,
        isRerunAfterEdit: Bool
    ) async throws {
        report.modeUsed = "Data"
        report.analysisTask = plan.task?.rawValue

        // Speak a filler right away so the user hears something within a second.
        if !isRerunAfterEdit {
            try? await speechOutput.speakText(plan.fillerText)
        }

        // Confidence gate: low OCR confidence → get the exact values from the clipboard.
        var table = extractedTable
        if table.extractionConfidence < Self.clipboardFallbackConfidenceThreshold, isClipboardFallbackEnabled {
            do {
                let clipboardTable = try await ClipboardTableExtractor.copyFrontmostSheetAsTable()
                table = ClipboardTableExtractor.merge(clipboardTable: clipboardTable, ocrTable: extractedTable)
                report.extractionSource = table.source
                report.extractionConfidence = table.extractionConfidence
                report.tableRowCount = table.rowCount
                report.tableColumnCount = table.columnCount
                print("📋 Clipboard merge: \(table.rowCount)×\(table.columnCount) rows, \(table.rowCellBoxes.filter { $0.contains { $0 != nil } }.count) visible")
            } catch {
                print("📋 Clipboard fallback unavailable, using OCR table: \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()

        let analysisStartedAt = Date()
        let outcome = try await dataModePipeline.run(plan: plan, table: table, chart: chart)
        report.analysisSeconds = Date().timeIntervalSince(analysisStartedAt)
        try Task.checkCancellation()

        if let drivers = outcome.response.drivers {
            report.metricText = "\(drivers.metricName) \(String(format: "%.2f", drivers.metricValue)) · trained \(String(format: "%.1f", drivers.trainSeconds))s"
        } else if let anomaly = outcome.response.anomaly {
            report.metricText = "\(anomaly.rows.count) rows flagged · \(anomaly.method)"
        } else if let fit = outcome.response.fit {
            report.metricText = "\(fit.modelName) · R² \(String(format: "%.2f", fit.rSquared))"
        }

        // Draw first, then speak — the judge sees the answer before hearing it.
        drawingLayerModel.show(outcome.primitives, geometry: capture.geometry, autoClearAfterSeconds: Self.drawingAutoClearSeconds)
        ClickyAnalytics.trackAIResponseReceived(response: outcome.spokenText)
        try await speak(isRerunAfterEdit ? "updated. " + outcome.spokenText : outcome.spokenText)

        // Edit-and-re-run: watch the table region; when it changes and settles, redo the same task.
        if let tableRegion = table.tableBoundingBoxInCapturePixels {
            let rerunTranscript = report.transcript
            screenChangeWatcher.start(regionInCapturePixels: tableRegion, geometry: capture.geometry) { [weak self] in
                guard let self, self.currentResponseTask == nil else { return }
                print("🔁 Table region changed — re-running \(plan.task?.rawValue ?? "analysis")")
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

    private func runClinicalMode(
        intent: ClinicalIntent,
        reading: ClinicalScreenReading,
        capture: SounderScreenCapture,
        report: inout SounderInteractionReport,
        isRerunAfterEdit: Bool
    ) async throws {
        report.modeUsed = "Rx"
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
            if !isRerunAfterEdit { try? await speechOutput.speakText("pulling the latest evidence") }
            outcome = try await clinicalModePipeline.evidence(reading: reading, conditionQuery: conditionQuery)
        case .checkMedications, .none:
            report.analysisTask = "check"
            guard !reading.medications.isEmpty else {
                try await speak("i see diagnoses but no medication list on this screen.")
                return
            }
            if !isRerunAfterEdit { try? await speechOutput.speakText("checking the med list") }
            outcome = try await clinicalModePipeline.checkMedications(reading: reading)
        }
        report.analysisSeconds = Date().timeIntervalSince(analysisStartedAt)
        report.metricText = outcome.metricText
        try Task.checkCancellation()

        drawingLayerModel.show(outcome.primitives, geometry: capture.geometry, autoClearAfterSeconds: 90)
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
        report: inout SounderInteractionReport
    ) async throws {
        report.modeUsed = "General"
        // Instant (pre-synthesized) so the wait for the vision model is not silent.
        try? await speechOutput.speakText("let me look")
        let answerStartedAt = Date()
        let answer = try await generalModePipeline.answer(
            transcript: transcript,
            capture: capture,
            elements: elements,
            conversationHistory: conversationHistory
        )
        report.planSeconds = Date().timeIntervalSince(answerStartedAt)
        try Task.checkCancellation()

        conversationHistory.append(FireworksChatClient.PriorTurn(userText: transcript, assistantText: answer.spokenText))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }

        if !answer.highlightedElements.isEmpty {
            drawingLayerModel.show(
                DrawingOpsBuilder.highlightElements(answer.highlightedElements),
                geometry: capture.geometry,
                autoClearAfterSeconds: 12
            )
        }

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
    }

    /// Speaks and flips the cursor into the responding state while audio plays.
    private func speak(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
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
        report.totalSeconds = Date().timeIntervalSince(startedAt)
        lastInteractionReport = report
        print("⏱️ \(report.modeUsed): capture \(String(format: "%.2f", report.captureSeconds))s, ocr \(String(format: "%.2f", report.ocrSeconds))s, plan \(String(format: "%.2f", report.planSeconds))s, analysis \(String(format: "%.2f", report.analysisSeconds))s, total \(String(format: "%.2f", report.totalSeconds))s")
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

    // MARK: - Screen analysis

    private func makeScreenAnalysisTask() -> Task<ScreenAnalysis, Error> {
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
            let table = TableExtractor.extractTable(from: textLines, imageSize: capture.pixelSize)
            let chart = ChartRegionDetector.detectChart(in: textLines, imageSize: capture.pixelSize, excluding: table?.tableBoundingBoxInCapturePixels)
            let clinicalReading = ClinicalEntityExtractor.extract(from: textLines, lexicon: clinicalLexicon)
            if !clinicalReading.isEmpty {
                print("💊 Chart: \(clinicalReading.medications.count) meds \(clinicalReading.medications.map { "\($0.name) \($0.doseMilligrams.map { "\($0)mg" } ?? "")×\($0.dosesPerDay ?? 0)" }), \(clinicalReading.conditions.count) conditions \(clinicalReading.conditions.map(\.canonicalName)), labs \(clinicalReading.labs.map { "\($0.key)=\($0.value)" }), age \(clinicalReading.ageYears ?? -1) \(clinicalReading.sex ?? "")")
            }
            return ScreenAnalysis(capture: capture, textLines: textLines, elements: elements, table: table, chart: chart,
                                  clinicalReading: clinicalReading, captureSeconds: captureSeconds, ocrSeconds: ocrSeconds)
        }
    }

    /// Auto mode only treats a grid as data when it looks like one: enough rows,
    /// typed columns and real header names. IDE side bars and log panes produce
    /// "tables" of text otherwise.
    private static func isPlausibleDataTable(_ table: ExtractedTable) -> Bool {
        guard table.extractionConfidence >= automaticModeTableConfidenceThreshold,
              table.rowCount >= 4, table.columnCount >= 2 else { return false }
        let typedColumnCount = table.columnTypes.filter { $0 == .numeric || $0 == .categorical || $0 == .date }.count
        guard typedColumnCount >= 2 else { return false }
        let namedHeaderCount = table.headers.filter { !$0.hasPrefix("Column ") }.count
        return namedHeaderCount >= max(2, table.columnCount / 2)
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
                var primitives = DrawingOpsBuilder.calibrationOutlines(elements)
                if let table = TableExtractor.extractTable(from: textLines, imageSize: capture.pixelSize),
                   let tableBox = table.tableBoundingBoxInCapturePixels {
                    primitives.append(.circle(id: "calibration-table", rectInCapturePixels: tableBox.insetBy(dx: -6, dy: -6), tagNumber: nil, color: .red))
                    primitives.append(.badge(id: "calibration-table-label", anchorInCapturePixels: CGPoint(x: tableBox.minX, y: tableBox.minY - 14),
                                             text: "table \(table.rowCount)×\(table.columnCount) · \(Int(table.extractionConfidence * 100))%"))
                }
                drawingLayerModel.show(primitives, geometry: capture.geometry, autoClearAfterSeconds: 5)
                var report = SounderInteractionReport(transcript: "(calibration)", modeUsed: "Calibration")
                report.tableRowCount = TableExtractor.extractTable(from: textLines, imageSize: capture.pixelSize)?.rowCount
                report.extractionConfidence = TableExtractor.extractTable(from: textLines, imageSize: capture.pixelSize)?.extractionConfidence
                report.totalSeconds = 0
                lastInteractionReport = report
                print("📐 Calibration: \(elements.count) text lines outlined on \(capture.geometry.captureWidthInPixels)×\(capture.geometry.captureHeightInPixels) capture")
            } catch {
                print("⚠️ Calibration failed: \(error)")
            }
        }
    }

    // MARK: - Transient cursor

    /// If the cursor is in transient mode (user toggled "Show Sounder" off), waits for
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
