import AppKit

@MainActor
final class ShortcutRecorderControl: NSButton {
    var shortcut: GlobalShortcut? {
        didSet { updateTitle() }
    }
    var onChange: ((GlobalShortcut?) -> Bool)?

    private var isRecording = false {
        didSet {
            updateTitle()
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("Global shortcut")
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func beginRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 { // Escape cancels recording.
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete clears it.
            if onChange?(nil) != false { shortcut = nil }
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        guard modifiers.hasPrimaryModifier,
              let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            NSSound.beep()
            return
        }

        let keyLabel = Self.displayLabel(for: event, characters: characters)
        let candidate = GlobalShortcut(keyCode: event.keyCode, modifiers: modifiers, keyLabel: keyLabel)
        if onChange?(candidate) != false {
            shortcut = candidate
            isRecording = false
            window?.makeFirstResponder(nil)
        } else {
            NSSound.beep()
        }
    }

    private func updateTitle() {
        title = isRecording ? "TYPE SHORTCUT" : (shortcut?.displayName ?? "RECORD SHORTCUT")
        setAccessibilityValue(shortcut?.displayName ?? "Not set")
    }

    private static func displayLabel(for event: NSEvent, characters: String) -> String {
        switch event.keyCode {
        case 36: "↩"
        case 48: "⇥"
        case 49: "SPACE"
        case 51: "⌫"
        case 53: "⎋"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: characters.uppercased()
        }
    }
}
