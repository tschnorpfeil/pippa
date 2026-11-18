// Accessibility actions for check-cloud-sharing.py, limited to the synthetic app's process.
import AppKit
import ApplicationServices

func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value as? T
}

func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 24 else { return [] }
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
    return [element] + children.flatMap { descendants($0, depth: depth + 1) }
}

func labels(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attribute(element, $0) }
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else { exit(2) }
if args[2] == "quit" {
    exit(NSRunningApplication(processIdentifier: pid)?.terminate() == true ? 0 : 1)
}
let app = AXUIElementCreateApplication(pid)
let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
let elements = windows.flatMap { descendants($0) }
if args[2] == "compose", args.count == 4, let input = elements.last(where: {
    (attribute($0, kAXRoleAttribute) as String?) == "AXTextField"
}) {
    exit(AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, args[3] as CFString) == .success ? 0 : 1)
}
for element in elements {
    let role: String = attribute(element, kAXRoleAttribute) ?? ""
    let names = labels(element)
    switch args[2] {
    case "tree":
        print(([role] + names).joined(separator: " | "))
    case "press" where args.count == 4:
        if ["AXButton", "AXMenuButton", "AXMenuItem", "AXPopUpButton"].contains(role), names.contains(args[3]) {
            exit(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? 0 : 1)
        }
    case "edit" where args.count == 5:
        let value: String = attribute(element, kAXValueAttribute) ?? ""
        if role == "AXTextArea", value.contains(args[3]) {
            exit(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, args[4] as CFString) == .success ? 0 : 1)
        }
    default: break
    }
}
exit(args[2] == "tree" ? 0 : 1)
