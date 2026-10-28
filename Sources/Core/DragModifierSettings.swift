import AppKit
import Foundation

/// Default Tangerine mapping (⇧ convert · ⌘ tools · ⌃ actions). Remappable later via Settings.
struct DragModifierSettings: Sendable {
    var convert: NSEvent.ModifierFlags = .shift
    var fileTools: NSEvent.ModifierFlags = .command
    var fileActions: NSEvent.ModifierFlags = .control

    static var `default` = DragModifierSettings()

    /// Resolve active fan mode from current flags. Priority: control > command > shift
    /// when multiple are held (rare).
    func mode(from flags: NSEvent.ModifierFlags) -> FanMode? {
        let relevant = flags.intersection([.shift, .command, .control, .option])
        if relevant.contains(fileActions) { return .fileActions }
        if relevant.contains(fileTools) { return .fileTools }
        if relevant.contains(convert) { return .convert }
        return nil
    }
}

extension FanMode {
    var title: String {
        switch self {
        case .convert: return "Convert"
        case .fileTools: return "Tools"
        case .fileActions: return "Actions"
        }
    }

    var shortcutHint: String {
        switch self {
        case .convert: return "⇧"
        case .fileTools: return "⌘"
        case .fileActions: return "⌃"
        }
    }

    /// SF Symbol for the fan hub (modifier key).
    var hubSymbolName: String {
        switch self {
        case .convert: return "shift"
        case .fileTools: return "command"
        case .fileActions: return "control"
        }
    }
}
