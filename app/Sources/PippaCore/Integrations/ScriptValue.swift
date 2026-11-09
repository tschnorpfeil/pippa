import Carbon
import Foundation

/// Handler parameters as plain values, so they can cross to the AppleScript queue.
enum ScriptArgument: Sendable {
    case text(String), number(Int32), texts([String])

    var descriptor: NSAppleEventDescriptor {
        switch self {
        case .text(let s): return NSAppleEventDescriptor(string: s)
        case .number(let n): return NSAppleEventDescriptor(int32: n)
        case .texts(let strings):
            let list = NSAppleEventDescriptor.list()
            for (i, s) in strings.enumerated() { list.insert(NSAppleEventDescriptor(string: s), at: i + 1) }
            return list
        }
    }
}

/// A script result as plain values (lists, texts, integers), read on the AppleScript queue.
indirect enum ScriptValue: Sendable {
    case text(String), number(Int), flag(Bool), list([ScriptValue]), other

    init(_ d: NSAppleEventDescriptor) {
        switch d.descriptorType {
        case typeAEList: self = .list(AppleEvents.items(d).map(ScriptValue.init))
        case typeSInt32: self = .number(Int(d.int32Value))
        case typeTrue, typeFalse, typeBoolean: self = .flag(d.booleanValue)
        default: self = d.stringValue.map(ScriptValue.text) ?? .other
        }
    }

    var text: String? { if case .text(let s) = self { return s }; return nil }
    var flag: Bool? { if case .flag(let b) = self { return b }; return nil }
    var number: Int? { if case .number(let n) = self { return n }; return nil }
    var items: [ScriptValue] { if case .list(let l) = self { return l }; return [] }
}
