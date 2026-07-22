import SwiftUI
import AppKit

/// Preferences window — SwiftUI hosted in a standard `NSWindow`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: ConfigurationStore
    private let permissions: PermissionManager
    private let usageStore: LLMUsageStore
    private let historyStore: TranscriptHistoryStore
    private let onPermissionsChanged: (() -> Void)?

    init(
        store: ConfigurationStore,
        permissions: PermissionManager,
        usageStore: LLMUsageStore,
        historyStore: TranscriptHistoryStore,
        onPermissionsChanged: (() -> Void)? = nil
    ) {
        self.store = store
        self.permissions = permissions
        self.usageStore = usageStore
        self.historyStore = historyStore
        self.onPermissionsChanged = onPermissionsChanged
        super.init()
    }

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView(
            store: store,
            permissions: permissions,
            usageStore: usageStore,
            historyStore: historyStore,
            onPermissionsChanged: onPermissionsChanged
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(Constants.appName) Preferences"
        window.contentViewController = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        applyTheme(store.configuration.theme, to: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        store.saveAPIKeysFromUI()
    }

    private func applyTheme(_ theme: AppTheme, to window: NSWindow) {
        switch theme {
        case .system:
            window.appearance = nil
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ConfigurationStore
    let permissions: PermissionManager
    @ObservedObject var usageStore: LLMUsageStore
    @ObservedObject var historyStore: TranscriptHistoryStore
    var onPermissionsChanged: (() -> Void)?

    @State private var permissionRefreshToken = UUID()

    var body: some View {
        TabView {
            settingsTab
                .tabItem { Label("Settings", systemImage: "gearshape") }

            HistoryView(historyStore: historyStore)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(minWidth: 520, minHeight: 600)
        .onChange(of: store.configuration.theme) { _, newTheme in
            applyAppAppearance(newTheme)
        }
        .onAppear { applyAppAppearance(store.configuration.theme) }
        .onDisappear { store.saveAPIKeysFromUI() }
    }

    private var settingsTab: some View {
        Form {
            Section("Speech") {
                Picker("Engine", selection: $store.configuration.speechEngine) {
                    Text("WhisperKit (Local)").tag(SpeechEngine.whisperKit)
                    Text("Apple Speech").tag(SpeechEngine.appleSpeech)
                }
                TextField("Whisper model", text: $store.configuration.whisperModel)
                    .disabled(store.configuration.speechEngine != .whisperKit)
            }

            Section("Formatting") {
                Picker("Mode", selection: $store.configuration.formattingMode) {
                    Text("Local Only (Ollama)").tag(FormattingMode.localOnly)
                    Text("Groq Only").tag(FormattingMode.groqOnly)
                    Text("OpenAI Only").tag(FormattingMode.openAIOnly)
                    Text("Auto Fallback (Ollama → Groq → OpenAI)").tag(FormattingMode.autoFallback)
                }
                TextField("Ollama model", text: $store.configuration.ollamaModel)
                TextField("Groq model", text: $store.configuration.groqModel)
                TextField("OpenAI model", text: $store.configuration.openAIModel)

                SecureField("Groq API Key", text: $store.groqAPIKey)
                    .onSubmit { store.saveAPIKeysFromUI() }
                SecureField("OpenAI API Key", text: $store.openAIAPIKey)
                    .onSubmit { store.saveAPIKeysFromUI() }

                if store.loadedKeysFromEnv {
                    Text("Keys also loaded from `.env` / environment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reload .env") {
                    store.reloadEnvironment()
                }

                HStack {
                    Text("Temperature")
                    Slider(value: $store.configuration.temperature, in: 0...1, step: 0.05)
                    Text(store.configuration.temperature, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Ollama timeout (s)")
                    TextField("", value: $store.configuration.ollamaTimeout, format: .number)
                        .frame(width: 60)
                }
            }

            Section("Provider Usage · Last 48 Hours") {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    ProviderUsageRow(provider: provider, usageStore: usageStore)
                }

                HStack {
                    if let provider = usageStore.mostRecentlyUsedProvider {
                        Text("Last successful provider: \(provider.displayName)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No successful formatting requests recorded yet.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if usageStore.totalInRollingWindow > 0 {
                        Button("Clear History", role: .destructive) {
                            usageStore.clear()
                        }
                        .controlSize(.small)
                    }
                }
                .font(.caption)

                Text("Counts successful formatting requests only. API keys and transcript text are never stored in usage history.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Appearance") {
                Picker("Theme", selection: $store.configuration.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
            }

            Section("Hotkeys") {
                LabeledContent("Toggle dictation", value: "⌘⇧Space")
                LabeledContent("Start dictation", value: "Double-tap Left ⌘")
                LabeledContent("Stop recording", value: "Tap Left ⌘ once")
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", permission: .microphone, manager: permissions)
                PermissionRow(title: "Speech Recognition", permission: .speechRecognition, manager: permissions)
                PermissionRow(title: "Accessibility", permission: .accessibility, manager: permissions)
                PermissionRow(title: "Input Monitoring", permission: .inputMonitoring, manager: permissions)

                HStack {
                    Button("Request Missing…") {
                        Task {
                            _ = await permissions.requestMicrophone()
                            _ = await permissions.requestSpeechRecognition()
                            permissions.requestAccessibility()
                            permissions.requestInputMonitoring()
                            permissionRefreshToken = UUID()
                            onPermissionsChanged?()
                        }
                    }
                    Button("Refresh Status") {
                        permissionRefreshToken = UUID()
                        onPermissionsChanged?()
                    }
                }
                .id(permissionRefreshToken)
            }

            Section {
                Text(Constants.Build.installLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func applyAppAppearance(_ theme: AppTheme) {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var historyStore: TranscriptHistoryStore

    var body: some View {
        VStack(spacing: 0) {
            if historyStore.entries.isEmpty {
                ContentUnavailableView(
                    "No Transcripts Yet",
                    systemImage: "text.badge.checkmark",
                    description: Text("Your last \(TranscriptHistoryStore.maxEntries) dictations will appear here. Use Copy if a paste didn't land in another app.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(historyStore.entries) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            HStack {
                Text("Keeps the last \(TranscriptHistoryStore.maxEntries) transcripts, stored only on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !historyStore.entries.isEmpty {
                    Button("Clear History", role: .destructive) {
                        historyStore.clear()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }
}

private struct HistoryRow: View {
    let entry: TranscriptHistoryStore.Entry
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.timeLabel(entry.timestamp))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let duration = entry.durationSeconds {
                    Text(Self.durationLabel(duration))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                if let model = entry.transcriptionModel {
                    Label(model, systemImage: "waveform")
                }
                if let provider = entry.provider {
                    Label("\(provider.displayName) formatting", systemImage: provider.symbolName)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)

            Text(entry.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private static func durationLabel(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1f s", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%dm %.0fs", minutes, remainder)
    }

    private static func timeLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today \(date.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ProviderUsageRow: View {
    let provider: LLMProvider
    @ObservedObject var usageStore: LLMUsageStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.symbolName)
                .foregroundStyle(providerColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .fontWeight(.medium)
                Text(provider.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(usageStore.count(for: provider))")
                    .font(.title3.monospacedDigit().weight(.semibold))
                if let lastUsed = usageStore.lastUsed(for: provider) {
                    // Static timestamp — a live `style: .relative` label ticks
                    // every second like a stopwatch.
                    Text(Self.lastUsedLabel(lastUsed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not used")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var providerColor: Color {
        switch provider {
        case .ollama: return .purple
        case .groq: return .orange
        case .openAI: return .green
        }
    }

    private static func lastUsedLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today \(date.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct PermissionRow: View {
    let title: String
    let permission: PermissionManager.Permission
    let manager: PermissionManager

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(statusLabel)
                .foregroundStyle(statusColor)
                .font(.caption.weight(.medium))
            Button("Open Settings") {
                manager.openSystemSettings(for: permission)
            }
            .controlSize(.small)
        }
    }

    private var status: PermissionManager.Status {
        manager.status(for: permission)
    }

    private var statusLabel: String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: return .green
        case .denied, .restricted: return .orange
        case .notDetermined: return .secondary
        }
    }
}
