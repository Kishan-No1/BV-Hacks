import AppKit
import Foundation
import NodCore

/// Connects the composer to its real services: the learned style file, the Anthropic polish call, the local
/// git context and the tmux send path. Also owns the menu actions around them.
@MainActor
final class ComposerWiring {
    static let polishDefaultsKey = "polishEnabled"

    let styleURL: URL
    let styleStore: StyleProfileStore
    let panesDirectory: URL
    /// `--test-compose`: the offline stub polisher, polish always on, a short "Sent" card.
    let testMode: Bool
    private let defaults: UserDefaults

    init(options: LaunchOptions, defaults: UserDefaults = .standard) {
        styleURL = options.styleFile.map { URL(fileURLWithPath: $0) } ?? StyleProfileStore.defaultFileURL
        styleStore = StyleProfileStore(fileURL: styleURL)
        panesDirectory = options.panesDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PaneRegistry.defaultDirectory
        testMode = options.testCompose != nil
        self.defaults = defaults
    }

    /// The menu toggle. Off: the composer sends the text as written and makes no network call.
    var polishEnabled: Bool {
        get { testMode || (defaults.object(forKey: Self.polishDefaultsKey) as? Bool ?? true) }
        set { defaults.set(newValue, forKey: Self.polishDefaultsKey) }
    }

    func install(on composer: ComposerModel) {
        let styleStore = self.styleStore
        var services = ComposerModel.Services(
            polisher: testMode ? StubPolisher() as any Polishing : AnthropicPolisher(),
            context: GitRepoContextProvider(),
            sender: LocatingTmuxSender(registry: PaneRegistry(directory: panesDirectory)),
            topNotes: { styleStore.profile.topNotes() },
            record: { styleStore.record($0) },
            polishEnabled: { [weak self] in self?.polishEnabled ?? true },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
        if testMode { services.sentDuration = 0.3 }
        composer.services = services
    }

    // MARK: Menu actions

    /// "Set Anthropic API key…": a secure field; the key goes to the login Keychain and nowhere else.
    func promptForAPIKey() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Anthropic API key"
        alert.informativeText = "Used only for Polish. Stored in your login Keychain (service “\(APIKeyProvider.keychainService)”). "
            + "An ANTHROPIC_API_KEY environment variable takes priority when Nod is started from a shell."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove key")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            do {
                try APIKeyProvider.saveToKeychain(key)
                Log.info("polish: API key saved to the Keychain")
            } catch {
                Log.info("polish: could not save the API key to the Keychain")
                HookInstaller.alert(title: "Could not save the key", text: "The Keychain refused the item.")
            }
        case .alertThirdButtonReturn:
            APIKeyProvider.deleteFromKeychain()
            Log.info("polish: API key removed from the Keychain")
        default:
            break
        }
    }

    func revealStyle() {
        if FileManager.default.fileExists(atPath: styleURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([styleURL])
        } else {
            HookInstaller.alert(title: "Nothing learned yet", text: "The style profile is created the first time you send a prompt from the composer:\n\(styleURL.path)")
        }
    }

    func confirmAndResetStyle() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Reset the learned style?"
        alert.informativeText = "This deletes every style note and the stored prompt history in\n\(styleURL.path)"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        styleStore.reset()
        Log.info("style: profile reset")
    }
}

/// Looks tmux up at send time, so installing tmux does not need a restart of Nod.
private struct LocatingTmuxSender: PromptSending {
    let registry: PaneRegistry

    func send(text: String, sessionID: String, cwd: String) async -> SendResult {
        let tmux = TmuxLocator.find(env: ProcessInfo.processInfo.environment) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        return await TmuxPromptSender(registry: registry, tmuxPath: tmux).send(text: text, sessionID: sessionID, cwd: cwd)
    }
}
