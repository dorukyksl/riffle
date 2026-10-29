import Cocoa

let arguments = CommandLine.arguments
var diagnosticsDirectory: String?
if let index = arguments.firstIndex(of: "--diag") {
    diagnosticsDirectory = arguments.indices.contains(index + 1) ? arguments[index + 1] : NSTemporaryDirectory() + "riffle-diag"
}

let application = NSApplication.shared
let appDelegate = AppDelegate(diagnosticsDirectory: diagnosticsDirectory)
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
