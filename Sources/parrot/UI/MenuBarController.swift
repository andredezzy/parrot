import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let inputItem: NSMenuItem
    private let modelItem: NSMenuItem
    private var model: TranscriptionModel
    private let devices: InputDeviceStore
    /// Set after construction: switching needs the daemon, and the daemon needs
    /// the controller it reports back to.
    var onModel: ((TranscriptionModel) -> Void)?

    init(model: TranscriptionModel, devices: InputDeviceStore) {
        self.model = model
        self.devices = devices
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle · hold fn to dictate", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(model.id)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        let inputMenu = NSMenu()
        inputMenu.autoenablesItems = false
        inputItem.submenu = inputMenu
        menu.addItem(inputItem)

        modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        modelMenu.autoenablesItems = false
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let example = NSMenuItem(
            title: "Edit dictation example…",
            action: #selector(editDictationExample),
            keyEquivalent: "")
        menu.addItem(example)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        super.init()

        example.target = self
        quit.target = self
        menu.addItem(quit)

        // Rebuild the device list on open so plugging a mic in is reflected
        // without watching CoreAudio for device changes.
        menu.delegate = self

        statusItem.menu = menu
        configureButton(recording: false)
    }

    /// Creates the file on first use so the format is explained where it is
    /// edited, then hands it to whatever opens .txt.
    @objc private func editDictationExample() {
        do {
            try DictationExample.ensureFileExists()
            NSWorkspace.shared.open(DictationExample.file)
        } catch {
            FileHandle.standardError.write(Data("could not open dictation example: \(error)\n".utf8))
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let submenu = inputItem.submenu else { return }
        submenu.removeAllItems()

        let selected = devices.selectedUID
        submenu.addItem(inputChoice(title: "Same as System", uid: nil, checked: selected == nil))
        submenu.addItem(.separator())
        for device in devices.available() {
            submenu.addItem(inputChoice(title: device.name, uid: device.uid, checked: device.uid == selected))
        }

        guard let modelSubmenu = modelItem.submenu else { return }
        modelSubmenu.removeAllItems()
        for candidate in ModelRegistry.shared {
            let active = candidate.id == model.id
            let item = NSMenuItem(
                title: "\(candidate.displayName) · \(candidate.sizeMB) MB",
                action: #selector(modelSelected),
                keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.id
            item.state = active ? .on : .off
            // Only the model in use is kept on disk, so every other row means a
            // download before the next dictation works.
            item.isEnabled = !active
            modelSubmenu.addItem(item)
        }
    }

    private func inputChoice(title: String, uid: String?, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(inputSelected), keyEquivalent: "")
        item.target = self
        item.representedObject = uid
        item.state = checked ? .on : .off
        return item
    }

    /// Only writes the preference — the next recording resolves it, so there is
    /// nothing to notify.
    @objc private func inputSelected(_ sender: NSMenuItem) {
        devices.selectedUID = sender.representedObject as? String
    }

    /// Hands the choice to the daemon, which loads it before dropping the model
    /// in use. The label follows on `setModel` once that succeeds.
    @objc private func modelSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let chosen = ModelRegistry.find(id), chosen.id != model.id
        else { return }
        modelLabel.title = "model: \(model.id) → \(chosen.id)…"
        onModel?(chosen)
    }

    func setModel(_ model: TranscriptionModel) {
        self.model = model
        modelLabel.title = "model: \(model.id)"
    }

    func setModelFailed(_ attempted: TranscriptionModel) {
        modelLabel.title = "model: \(model.id) · \(attempted.id) failed"
    }

    func setRecording(_ recording: Bool) {
        stateLabel.title = recording ? "● recording" : "idle · hold fn to dictate"
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
