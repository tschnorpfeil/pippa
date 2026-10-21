import ApplicationServices
import Darwin
import Foundation

// Public, read-only external AX traversal for the synthetic app fixture. Never changes TCC permissions.
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fputs("Expected the fixture app's process ID.\n", stderr)
    exit(2)
}
let application = AXUIElementCreateApplication(pid)
let deadline = Date().addingTimeInterval(130)
var successfulReads = 0
var lastError: AXError?
print("Accessibility client trusted: \(AXIsProcessTrusted())")

func visit(_ element: AXUIElement, depth: Int, remaining: inout Int) {
    guard depth < 40, remaining > 0 else { return }
    remaining -= 1
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
       let children = value as? [AXUIElement] {
        for child in children { visit(child, depth: depth + 1, remaining: &remaining) }
    }
}

while Date() < deadline, kill(pid, 0) == 0 {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
    if result == .success, let windows = value as? [AXUIElement], !windows.isEmpty {
        successfulReads += 1
        var remaining = 10_000
        for window in windows { visit(window, depth: 0, remaining: &remaining) }
    } else if result != .success, result != lastError {
        print("AX window read returned \(result.rawValue).")
        lastError = result
    }
    Thread.sleep(forTimeInterval: 0.1)
}
print("Successful external AX window reads: \(successfulReads)")
if successfulReads == 0 {
    fputs("FAIL: no external AX tree could be read. The native first-use acceptance must not skip its accessibility assertions.\n", stderr)
    exit(1)
}
