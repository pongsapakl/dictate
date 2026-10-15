import SwiftUI
import AppKit
import AVFoundation
import Speech
import Combine
import Quartz
import os
import UserNotifications
import UniformTypeIdentifiers

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

let supportedLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("de", "German"), ("es", "Spanish"), ("fr", "French"), ("it", "Italian"),
    ("pt", "Portuguese"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("ar", "Arabic")
]

@main
struct WhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var analyzerFormat: AVAudioFormat?
    private var currentLocale = Locale(identifier: "en_US")
    private var dictation: Dictation?
    private var microphone: MicrophoneCapture?
    private var releasedAt = Date()
    private var isRecording = false
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var screenGlow: ScreenGlow?
    private var launcherPanel: LauncherPanel?
    private var statusMenu: NSMenu?
    private var hotkeyDown = false
    private var keyPressedDuringHotkey = false
    private var hotkeyMenu: NSMenu?
    private var iconAnimationTimer: Timer?
    private var iconAnimationFrame: Int = 0
    private var lastLiveText: String = ""
    private var isLatched = false
    private var hotkeyPressTime: Date?
    private var pendingStop: Task<Void, Never>?
    private var suppressNextRelease = false
    private let tapThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.3
    private let pasteDelay: TimeInterval = 0.25
    private let releaseGrace: TimeInterval = 0.15
    private let finishTimeout: TimeInterval = 5
    private let clipboardRestoreDelay: TimeInterval = 1
    private let recentLimit = 20
    private let watchdog = MainThreadWatchdog()
    private var recordingSessionId: Int = 0
    private var selectedLanguage: String {
        get { UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en" }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectedLanguage")
            updateLanguageMenu()
            Task { await prepareSpeechAssets() }
        }
    }
    private var engineMenu: NSMenu?
    private var selectedModule: SpeechModuleKind {
        get { SpeechModuleKind(rawValue: UserDefaults.standard.string(forKey: "speechModule") ?? "") ?? .transcriber }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "speechModule")
            engineMenu?.items.forEach { $0.state = ($0.representedObject as? String == newValue.rawValue) ? .on : .off }
            Task { await prepareSpeechAssets() }
        }
    }
    private var languageMenu: NSMenu?
    private var micMenu: NSMenu?
    private var selectedMicrophone: String? {
        get { UserDefaults.standard.string(forKey: "selectedMicrophone") }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: "selectedMicrophone")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedMicrophone")
            }
            updateMicMenu()
        }
    }
    private var recentMenu: NSMenu?
    private var recentTranscriptions: [TranscriptionRecord] = []
    private let transcriptionStore = TranscriptionStore()
    private var autoSendMenuItem: NSMenuItem?
    private var autoSend: Bool {
        get { UserDefaults.standard.bool(forKey: "autoSend") }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoSend")
            autoSendMenuItem?.state = newValue ? .on : .off
        }
    }
    private var selectedHotkey: String {
        get { UserDefaults.standard.string(forKey: "selectedHotkey") ?? "rightOption" }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectedHotkey")
            updateHotkeyMenu()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.notice("launched build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", privacy: .public)")
        watchdog.start()
        NSApp.setActivationPolicy(.accessory)
        terminateOtherInstances()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        requestPermissions()
        setupStatusItem()
        setupHotkeyMonitor()
        screenGlow = ScreenGlow()
        launcherPanel = LauncherPanel { [weak self] in self?.startRecording() }
        NotificationCenter.default.addObserver(forName: .transcribeFile, object: nil, queue: .main) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { await self?.transcribeFile(url: url) }
        }
        Task { await prepareSpeechAssets() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { await transcribeFile(url: url) }
        }
    }

    private func transcribeFile(url: URL) async {
        guard let format = analyzerFormat else {
            showNotification(title: "Whisper", message: "Speech engine is still starting. Try again in a moment.")
            return
        }
        guard !isRecording else {
            showNotification(title: "Whisper", message: "Finish dictating before transcribing a file.")
            return
        }
        log.notice("file transcription started")
        screenGlow?.show(mode: .transcribing)
        launcherPanel?.showFileTranscribing(fileName: url.lastPathComponent)
        updateIcon(.transcribing)

        let session = startAnalysis()
        if let buffer = await Task.detached(operation: { try? readAudioFile(url, as: format) }).value {
            session.input.yield(AnalyzerInput(buffer: buffer))
        }
        let text = TextPolish.apply(await finishAnalysis(session).text)
        log.notice("file transcription finished chars=\(text.count, privacy: .public)")

        if text.isEmpty {
            showNotification(title: "Whisper", message: "No speech detected in file.")
            launcherPanel?.resetToIdle()
        } else {
            saveTranscript(text)
            copyToPasteboard(text)
            launcherPanel?.showFileResult(text: text, fileName: url.lastPathComponent)
            showNotification(title: "Whisper", message: "Transcription copied to clipboard!")
        }
        screenGlow?.hide()
        updateIcon(.ready)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(.loading)

        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        statusMenu = NSMenu()
        statusMenu?.addItem(NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: ""))
        statusMenu?.addItem(NSMenuItem.separator())

        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageMenu = NSMenu()
        for lang in supportedLanguages {
            let item = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            languageMenu?.addItem(item)
        }
        langItem.submenu = languageMenu
        statusMenu?.addItem(langItem)
        updateLanguageMenu()

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenu = NSMenu()
        micMenu?.delegate = self
        micItem.submenu = micMenu
        statusMenu?.addItem(micItem)
        updateMicMenu()

        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineMenu = NSMenu()
        for kind in SpeechModuleKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == selectedModule ? .on : .off
            engineMenu?.addItem(item)
        }
        engineMenu?.addItem(.separator())
        let wordsItem = NSMenuItem(title: "Custom Words…", action: #selector(openVocabulary), keyEquivalent: "")
        wordsItem.target = self
        engineMenu?.addItem(wordsItem)
        engineItem.submenu = engineMenu
        statusMenu?.addItem(engineItem)

        let recentItem = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
        recentMenu = NSMenu()
        recentItem.submenu = recentMenu
        statusMenu?.addItem(recentItem)
        loadRecentTranscriptions()

        autoSendMenuItem = NSMenuItem(title: "Auto-Send (Press Enter)", action: #selector(toggleAutoSend), keyEquivalent: "")
        autoSendMenuItem?.target = self
        autoSendMenuItem?.state = autoSend ? .on : .off
        statusMenu?.addItem(autoSendMenuItem!)

        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        hotkeyMenu = NSMenu()
        let hotkeyOptions: [(id: String, name: String)] = [
            ("rightOption", "Right Option ⌥"),
            ("leftOption", "Left Option ⌥"),
            ("globe", "Globe 🌐")
        ]
        for opt in hotkeyOptions {
            let item = NSMenuItem(title: opt.name, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = opt.id
            hotkeyMenu?.addItem(item)
        }
        hotkeyItem.submenu = hotkeyMenu
        statusMenu?.addItem(hotkeyItem)
        updateHotkeyMenu()

        statusMenu?.addItem(NSMenuItem.separator())
        statusMenu?.addItem(NSMenuItem(title: "Restart Whisper", action: #selector(restart), keyEquivalent: ""))
        statusMenu?.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusMenu?.items.forEach { $0.target = self }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.modifierFlags.contains(.option) || event.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            launcherPanel?.updateStats(transcriptionCount: totalTranscriptionCount(), recentTexts: recentTranscriptions.map { $0.text })
            launcherPanel?.toggle()
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        selectedLanguage = sender.representedObject as? String ?? "en"
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        selectedModule = SpeechModuleKind(rawValue: sender.representedObject as? String ?? "") ?? .transcriber
    }

    @objc private func openVocabulary() {
        let url = UserFiles.url("Vocabulary.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "# One word or phrase per line. Passed as hints to Apple Dictation and auto-corrected in every result (WhisperKit fixes \"whisper kit\").\n# Explicit rewrites go in Replacements.txt next to this file, one per line:  wrong phrase => Right Phrase\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        selectedMicrophone = sender.representedObject as? String
    }

    private func updateMicMenu() {
        guard let micMenu else { return }
        micMenu.removeAllItems()
        let defaultItem = NSMenuItem(title: "System Default", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = selectedMicrophone == nil ? .on : .off
        micMenu.addItem(defaultItem)
        micMenu.addItem(.separator())
        for device in InputDevices.all() {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.name
            item.state = device.name == selectedMicrophone ? .on : .off
            micMenu.addItem(item)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == micMenu { updateMicMenu() }
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        selectedHotkey = sender.representedObject as? String ?? "rightOption"
    }

    private func updateHotkeyMenu() {
        hotkeyMenu?.items.forEach { item in
            let id = item.representedObject as? String
            item.state = (id == selectedHotkey) ? .on : .off
        }
    }

    @objc private func toggleAutoSend() {
        autoSend = !autoSend
    }

    private func updateLanguageMenu() {
        languageMenu?.items.forEach { item in
            let code = item.representedObject as? String
            item.state = (code == selectedLanguage) ? .on : .off
        }
    }

    private func terminateOtherInstances() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
            .forEach { $0.terminate() }
    }

    private func totalTranscriptionCount() -> Int {
        transcriptionStore.count()
    }

    private func loadRecentTranscriptions() {
        recentTranscriptions = transcriptionStore.loadRecent(limit: recentLimit)
        updateRecentMenu()
    }

    private func updateRecentMenu() {
        recentMenu?.removeAllItems()
        if recentTranscriptions.isEmpty {
            recentMenu?.addItem(NSMenuItem(title: "No transcriptions yet", action: nil, keyEquivalent: ""))
        }
        for record in recentTranscriptions.prefix(5) {
            var preview = record.text.replacingOccurrences(of: "\n", with: " ")
            if preview.count > 50 { preview = String(preview.prefix(50)) + "..." }
            let item = NSMenuItem(title: preview, action: #selector(copyTranscription(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.text
            recentMenu?.addItem(item)
        }
        recentMenu?.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openTranscriptsFolder), keyEquivalent: "")
        openItem.target = self
        recentMenu?.addItem(openItem)
    }

    @objc private func copyTranscription(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        copyToPasteboard(text)
        showNotification(title: "Whisper", message: "Copied to clipboard!")
    }

    @objc private func openTranscriptsFolder() {
        try? FileManager.default.createDirectory(at: transcriptionStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(transcriptionStore.directory)
    }

    private func setupHotkeyMonitor() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            Task { @MainActor in
                self?.handleChordInput()
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] _ in
            Task { @MainActor in
                self?.handleChordInput()
            }
        }
    }

    // The hotkey doubling as a chord modifier (option+arrow, option+click)
    // must not dictate: cancel the moment any other input lands mid-hold.
    private func handleChordInput() {
        guard hotkeyDown, !isLatched else { return }
        keyPressedDuringHotkey = true
        if isRecording { stopRecording(cancel: true) }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let hotkeyKeyCode: UInt16
        let modifierFlag: NSEvent.ModifierFlags

        switch selectedHotkey {
        case "leftOption":
            hotkeyKeyCode = 58
            modifierFlag = .option
        case "globe":
            hotkeyKeyCode = 63
            modifierFlag = .function
        default:
            hotkeyKeyCode = 61
            modifierFlag = .option
        }

        guard event.keyCode == hotkeyKeyCode else { return }

        let hotkeyPressed = event.modifierFlags.contains(modifierFlag)
        if hotkeyPressed && !hotkeyDown {
            hotkeyDown = true
            keyPressedDuringHotkey = false
            hotkeyPressTime = Date()

            if isLatched {
                suppressNextRelease = true
                stopRecording()
                return
            }

            if let pending = pendingStop {
                pending.cancel()
                pendingStop = nil
                isLatched = true
                suppressNextRelease = true
                return
            }

            if !isRecording { startRecording() }
        } else if !hotkeyPressed && hotkeyDown {
            hotkeyDown = false
            let heldFor = hotkeyPressTime.map { Date().timeIntervalSince($0) } ?? 0
            hotkeyPressTime = nil

            if suppressNextRelease {
                suppressNextRelease = false
                keyPressedDuringHotkey = false
                return
            }

            if keyPressedDuringHotkey {
                keyPressedDuringHotkey = false
                if isRecording { stopRecording(cancel: true) }
                return
            }

            if isLatched { return }

            if heldFor < tapThreshold {
                let window = doubleTapWindow
                pendingStop = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.pendingStop = nil
                    if self.isRecording { self.stopRecording() }
                }
                return
            }

            if isRecording { stopRecording() }
        }
    }

    private func prepareSpeechAssets() async {
        analyzerFormat = nil
        updateIcon(.loading)
        launcherPanel?.showLoading()
        launcherPanel?.updateLoadingProgress(0)
        log.notice("speech setup started language=\(self.selectedLanguage, privacy: .public) module=\(self.selectedModule.rawValue, privacy: .public)")
        var failed = false
        currentLocale = await selectedModule.supportedLocale(for: selectedLanguage) ?? Locale(identifier: "en_US")
        let module = selectedModule.makeModule(locale: currentLocale)
        _ = try? await AssetInventory.reserve(locale: currentLocale)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let observer = Task { [weak self] in
                    for await fraction in request.progress.publisher(for: \.fractionCompleted).values { self?.launcherPanel?.updateLoadingProgress(fraction) }
                }
                defer { observer.cancel() }
                try await request.downloadAndInstall()
            }
        } catch {
            failed = true
            log.error("speech asset install failed: \(error.localizedDescription, privacy: .public)")
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let warmup = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        do {
            try await warmup.prepareToAnalyze(in: format)
        } catch {
            failed = true
            log.error("speech warmup failed: \(error.localizedDescription, privacy: .public)")
        }
        analyzerFormat = format
        launcherPanel?.updateLoadingProgress(1)
        launcherPanel?.hideLoading()
        updateIcon(.ready)
        log.notice("speech setup finished failed=\(failed, privacy: .public)")
        if failed {
            showNotification(title: "Whisper", message: "Speech setup hit an error. If dictation doesn't work, use Restart Whisper in the menu.")
        } else {
            NSSound(named: .init("Tink"))?.play()
        }
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard let format = analyzerFormat else {
            showNotification(title: "Whisper", message: "Speech engine is still starting. Try again in a moment.")
            return
        }
        saveFocus()
        isRecording = true
        recordingSessionId += 1
        updateIcon(.recording)
        statusItem.menu?.item(at: 0)?.title = "Stop Recording"
        screenGlow?.show(mode: .recording)
        launcherPanel?.showRecording()

        let session = startAnalysis(sessionId: recordingSessionId)
        let input = session.input
        let capture = MicrophoneCapture()
        dictation = session
        microphone = capture
        do {
            try capture.start(
                deviceID: InputDevices.id(named: selectedMicrophone),
                format: format,
                onFailure: { [weak self] in Task { @MainActor in self?.microphoneLost() } },
                onBuffer: { input.yield(AnalyzerInput(buffer: $0)) })
            log.notice("recording started session=\(self.recordingSessionId, privacy: .public)")
        } catch {
            log.error("microphone failed to start: \(error.localizedDescription, privacy: .public)")
            showNotification(title: "Whisper", message: "Microphone failed to start.")
            stopRecording(cancel: true)
        }
    }

    private func microphoneLost() {
        guard isRecording else { return }
        log.error("microphone lost mid-recording, finishing with what was heard")
        stopRecording()
    }

    private func startAnalysis(sessionId: Int? = nil) -> Dictation {
        let module = selectedModule.makeModule(locale: currentLocale)
        let context = AnalysisContext()
        let vocabulary = UserFiles.vocabulary
        if !vocabulary.isEmpty { context.contextualStrings = [.general: vocabulary] }
        lastLiveText = ""
        let transcript = Transcript()
        let results = Task { [weak self] in
            for await result in speechResults(of: module) {
                transcript.add(result)
                self?.showLiveText(transcript.text, sessionId: sessionId)
            }
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime), analysisContext: context)
        return Dictation(analyzer: analyzer, input: input, results: results, transcript: transcript)
    }

    private func finishAnalysis(_ session: Dictation) async -> (text: String, timedOut: Bool) {
        session.input.finish()
        let (outcome, report) = AsyncStream<Bool>.makeStream()
        let work = Task {
            try? await session.analyzer.finalizeAndFinishThroughEndOfInput()
            await session.results.value
            report.yield(false)
        }
        let limit = finishTimeout
        let timer = Task {
            try await Task.sleep(for: .seconds(limit))
            report.yield(true)
        }
        var iterator = outcome.makeAsyncIterator()
        let timedOut = await iterator.next() ?? true
        timer.cancel()
        if timedOut {
            work.cancel()
            session.results.cancel()
            Task { await session.analyzer.cancelAndFinishNow() }
        }
        return (session.transcript.text, timedOut)
    }

    private func showLiveText(_ text: String, sessionId: Int?) {
        guard isRecording, sessionId == recordingSessionId, !text.isEmpty, text != lastLiveText else { return }
        lastLiveText = text
        launcherPanel?.updateLiveText(text)
    }

    private var savedWindow: AXUIElement?
    private var savedAppPid: pid_t = 0
    private var savedWindowId: CGWindowID = 0

    private func saveFocus() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        savedAppPid = frontApp.processIdentifier

        let appRef = AXUIElementCreateApplication(savedAppPid)
        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)

        if result == .success, let window = focusedWindowRef {
            savedWindow = (window as! AXUIElement)
            _ = _AXUIElementGetWindow(savedWindow!, &savedWindowId)
        } else {
            savedWindow = nil
            savedWindowId = 0
        }
    }

    private func stopRecording(cancel: Bool = false) {
        guard isRecording else { return }
        isRecording = false
        isLatched = false
        pendingStop?.cancel()
        pendingStop = nil
        releasedAt = Date()
        statusItem.menu?.item(at: 0)?.title = "Start Recording"

        let capture = microphone
        let session = dictation
        microphone = nil
        dictation = nil

        if cancel {
            log.notice("recording cancelled session=\(self.recordingSessionId, privacy: .public)")
            capture?.stop()
            session?.input.finish()
            session?.results.cancel()
            Task { await session?.analyzer.cancelAndFinishNow() }
            launcherPanel?.hideLiveText()
            screenGlow?.hide()
            launcherPanel?.resetToIdle()
            updateIcon(.ready)
            return
        }

        updateIcon(.transcribing)
        screenGlow?.show(mode: .transcribing)

        let sessionId = recordingSessionId
        log.notice("recording stopped session=\(sessionId, privacy: .public), finishing")
        Task {
            try? await Task.sleep(nanoseconds: UInt64(releaseGrace * 1_000_000_000))
            capture?.stop()
            guard let session else { return }
            let result = await finishAnalysis(session)
            log.notice("finished session=\(sessionId, privacy: .public) chars=\(result.text.count, privacy: .public) timedOut=\(result.timedOut, privacy: .public)")
            guard recordingSessionId == sessionId else {
                let text = TextPolish.apply(result.text)
                if !text.isEmpty {
                    saveTranscript(text)
                    showNotification(title: "Whisper", message: "Previous dictation saved to Recent Transcriptions.")
                }
                return
            }
            if result.timedOut {
                showNotification(title: "Whisper", message: "Transcription took too long. Pasted what was heard so far.")
            }
            finalizeSpeech(rawText: result.text, frames: capture?.capturedFrames ?? [])
        }
    }

    private func finalizeSpeech(rawText: String, frames: [Int16]) {
        let releaseToFinalMs = Int(Date().timeIntervalSince(releasedAt) * 1000)
        let finalText = TextPolish.apply(rawText)
        if finalText.isEmpty {
            log.notice("no speech detected")
            showNotification(title: "Whisper", message: "No speech detected. Try again.")
            screenGlow?.hide()
            launcherPanel?.resetToIdle()
            updateIcon(.ready)
            return
        }

        let timestamp = saveTranscript(finalText)
        restoreWindow()
        copyAndPaste(finalText)
        NSSound(named: .init("Pop"))?.play()
        launcherPanel?.hideLiveText()
        screenGlow?.hide()
        launcherPanel?.resetToIdle()
        updateIcon(.ready)

        let sampleRate = analyzerFormat?.sampleRate ?? 16000
        let entry = CorpusEntry(
            timestamp: timestamp,
            module: selectedModule.rawValue,
            locale: currentLocale.identifier,
            durationSeconds: Double(frames.count) / sampleRate,
            releaseToFinalMs: releaseToFinalMs,
            rawText: rawText,
            text: finalText,
            targetApp: NSRunningApplication(processIdentifier: savedAppPid)?.bundleIdentifier ?? "",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        Task.detached(priority: .utility) { Corpus.save(frames: frames, sampleRate: sampleRate, entry: entry) }
    }

    private func restoreWindow() {
        guard let window = savedWindow else { return }
        guard let app = NSRunningApplication(processIdentifier: savedAppPid) else { return }
        app.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    @discardableResult
    private func saveTranscript(_ text: String) -> String {
        let url = transcriptionStore.save(text)
        if url == nil { log.error("transcript save failed") }
        recentTranscriptions.insert(TranscriptionRecord(timestamp: "", text: text), at: 0)
        recentTranscriptions = Array(recentTranscriptions.prefix(recentLimit))
        updateRecentMenu()
        return url?.deletingPathExtension().lastPathComponent ?? ""
    }

    private func copyAndPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ownChange = pasteboard.changeCount

        let trusted = AXIsProcessTrusted()
        log.notice("pasting chars=\(text.count, privacy: .public) trusted=\(trusted, privacy: .public) target=\(NSRunningApplication(processIdentifier: self.savedAppPid)?.bundleIdentifier ?? "nil", privacy: .public) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)")

        if !trusted {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            showNotification(title: "Whisper", message: "Grant Accessibility permission, then try again. Text is in clipboard.")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            guard let self else { return }
            self.simulatePaste()
            guard !previous.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.clipboardRestoreDelay) {
                guard pasteboard.changeCount == ownChange else { return }
                pasteboard.clearContents()
                pasteboard.writeObjects(previous.map { types in
                    let item = NSPasteboardItem()
                    types.forEach { item.setData($1, forType: $0) }
                    return item
                })
            }
        }
    }

    private func simulatePaste() {
        let src = CGEventSource(stateID: .privateState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        if vDown == nil || vUp == nil { log.error("paste key events could not be created") }

        if autoSend {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == self.savedAppPid else {
                    log.notice("auto-send skipped, focus moved to another app")
                    return
                }
                let enterSrc = CGEventSource(stateID: .hidSystemState)
                let enterDown = CGEvent(keyboardEventSource: enterSrc, virtualKey: 36, keyDown: true)
                let enterUp = CGEvent(keyboardEventSource: enterSrc, virtualKey: 36, keyDown: false)
                enterDown?.flags = []
                enterUp?.flags = []
                enterDown?.post(tap: .cghidEventTap)
                enterUp?.post(tap: .cghidEventTap)
            }
        }
    }

    private func showNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private enum IconState { case loading, ready, recording, transcribing }
    private var currentIconState: IconState = .loading

    private func updateIcon(_ state: IconState) {
        iconAnimationTimer?.invalidate()
        iconAnimationTimer = nil
        currentIconState = state
        iconAnimationFrame = 0

        switch state {
        case .loading:
            animateLoading()
        case .ready:
            statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        case .recording:
            animateRecording()
        case .transcribing:
            animateTranscribing()
        }
    }

    private func animateLoading() {
        updateLoadingFrame()
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.iconAnimationFrame += 1
                self.updateLoadingFrame()
            }
        }
    }

    private func updateLoadingFrame() {
        guard let baseImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) else { return }
        let angle = CGFloat(iconAnimationFrame * 30)
        let gearSize: CGFloat = 14
        let canvasSize = NSSize(width: 18, height: 18)
        let rotated = NSImage(size: canvasSize, flipped: false) { _ in
            let context = NSGraphicsContext.current?.cgContext
            context?.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context?.rotate(by: angle * .pi / 180)
            let gearRect = NSRect(x: -gearSize / 2, y: -gearSize / 2, width: gearSize, height: gearSize)
            baseImage.draw(in: gearRect)
            return true
        }
        rotated.isTemplate = true
        statusItem.button?.image = rotated
    }

    private func animateRecording() {
        updateRecordingFrame()
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.iconAnimationFrame += 1
                self.updateRecordingFrame()
            }
        }
    }

    private func updateRecordingFrame() {
        let icons = ["mic", "mic.fill", "mic.fill", "mic"]
        let icon = icons[iconAnimationFrame % icons.count]
        statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
    }

    private func animateTranscribing() {
        updateTranscribingFrame()
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.iconAnimationFrame += 1
                self.updateTranscribingFrame()
            }
        }
    }

    private func updateTranscribingFrame() {
        let icons = ["ellipsis", "ellipsis", "sparkle", "ellipsis"]
        let icon = icons[iconAnimationFrame % icons.count]
        statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
    }

    @objc private func restart() {
        log.notice("restart requested")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { log.error("restart failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
