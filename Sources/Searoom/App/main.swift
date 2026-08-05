import AppKit

if CommandLine.arguments.contains("--self-test") {
    SearoomFont.registerBundledFont()
    let passed = SelfTest.run() && SearoomFont.isDepartureMonoAvailable
    if !SearoomFont.isDepartureMonoAvailable {
        fputs("Searoom self-test failed: bundled Departure Mono font\n", stderr)
    }
    if passed { print("Searoom self-test passed") }
    exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
}
if CommandLine.arguments.contains("--dump-sample") {
    exit(SelfTest.dumpSample() ? EXIT_SUCCESS : EXIT_FAILURE)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
