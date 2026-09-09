import AppKit
import Darwin

// Process entry point. Dispatch happens before any AppKit lifecycle object
// exists: the signed bundle executable with no arguments launches the GUI, a
// lowercase `searoom` symlink prints help, and every recognized command runs
// through the CLI without constructing NSApplication, AppDelegate, AppModel,
// or registering fonts.

let arguments = CommandLine.arguments

switch CLIParser.parse(arguments: arguments) {
case .launchGUI:
    AppLauncher.launch()
case .usageError(let error):
    exit(CLIRunner.usageError(error))
case .run(let command, let json, let pretty):
    exit(CLIRunner.run(command, json: json, pretty: pretty))
}
