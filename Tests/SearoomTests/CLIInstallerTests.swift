import Foundation
import XCTest
@testable import Searoom

final class CLIInstallerTests: XCTestCase {
    private var homeDirectory: URL!
    private var appDirectory: URL!
    private var executableURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("searoom-installer-tests-\(UUID().uuidString)", isDirectory: true)
        appDirectory = homeDirectory.appendingPathComponent("Applications/Searoom.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        executableURL = appDirectory.appendingPathComponent("Searoom")
        try Data("mach-o".utf8).write(to: executableURL)
    }

    override func tearDownWithError() throws {
        if let homeDirectory {
            try? fileManager.removeItem(at: homeDirectory)
        }
    }

    private var linkURL: URL {
        CLIInstaller.linkURL(homeDirectory: homeDirectory.path)
    }

    private func install() -> CLIInstaller.Outcome {
        CLIInstaller.install(homeDirectory: homeDirectory.path, executableURL: executableURL)
    }

    private func uninstall() -> CLIInstaller.Outcome {
        CLIInstaller.uninstall(homeDirectory: homeDirectory.path, executableURL: executableURL)
    }

    func testInstallCreatesOnlyTheExpectedSymlink() throws {
        let outcome = install()
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: linkURL.path),
            executableURL.standardizedFileURL.path
        )
        // Nothing else below the home directory besides the app and the link.
        let enumerator = fileManager.enumerator(at: homeDirectory, includingPropertiesForKeys: nil)
        let contents = enumerator?.allObjects as? [URL] ?? []
        let linkPath = linkURL.standardizedFileURL.path
        let executablePath = executableURL.standardizedFileURL.path
        let unexpected = contents.filter {
            let path = $0.standardizedFileURL.path
            return path != executablePath
                && path != linkPath
                && !path.contains("/Searoom.app")
                && !path.hasSuffix("/.local")
                && !path.hasSuffix("/.local/bin")
                && !path.hasSuffix("/Applications")
        }
        XCTAssertTrue(unexpected.isEmpty, "unexpected files: \(unexpected.map(\.path))")
    }

    func testInstallIsIdempotentForTheCorrectLink() {
        XCTAssertEqual(install().exitCode, 0)
        let second = install()
        XCTAssertEqual(second.exitCode, 0)
        XCTAssertTrue(second.message.contains("already"))
    }

    func testInstallNeverOverwritesARegularFile() throws {
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user file".utf8).write(to: linkURL)
        let outcome = install()
        XCTAssertEqual(outcome.exitCode, 65)
        XCTAssertEqual(try Data(contentsOf: linkURL), Data("user file".utf8))
    }

    func testInstallNeverOverwritesAnUnrelatedSymlink() throws {
        let unrelatedTarget = homeDirectory.appendingPathComponent("unrelated")
        try Data("x".utf8).write(to: unrelatedTarget)
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: unrelatedTarget)
        let outcome = install()
        XCTAssertEqual(outcome.exitCode, 65)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: linkURL.path), unrelatedTarget.path)
    }

    func testUninstallRemovesOnlyALinkTargetingTheCurrentApp() throws {
        _ = install()
        XCTAssertEqual(uninstall().exitCode, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: linkURL.path))
        // Removing again is a successful no-op.
        XCTAssertEqual(uninstall().exitCode, 0)
    }

    func testUninstallRefusesAnUnrelatedSymlink() throws {
        let unrelatedTarget = homeDirectory.appendingPathComponent("unrelated")
        try Data("x".utf8).write(to: unrelatedTarget)
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: unrelatedTarget)
        XCTAssertEqual(uninstall().exitCode, 65)
        XCTAssertTrue(fileManager.fileExists(atPath: linkURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedTarget.path))
    }

    func testUninstallRefusesARegularFile() throws {
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user file".utf8).write(to: linkURL)
        XCTAssertEqual(uninstall().exitCode, 65)
        XCTAssertTrue(fileManager.fileExists(atPath: linkURL.path))
    }

    func testMountedVolumeIsRejected() {
        let mounted = URL(fileURLWithPath: "/Volumes/Searoom 1.1/Searoom.app/Contents/MacOS/Searoom")
        XCTAssertNotNil(CLIInstaller.unstableLocationReason(for: mounted))
        XCTAssertEqual(
            CLIInstaller.install(homeDirectory: homeDirectory.path, executableURL: mounted).exitCode,
            65
        )
    }

    func testTranslocatedBundleIsRejected() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/Searoom.app/Contents/MacOS/Searoom")
        XCTAssertNotNil(CLIInstaller.unstableLocationReason(for: translocated))
    }

    func testNonBundlePathIsRejected() {
        let loose = URL(fileURLWithPath: "/tmp/Searoom")
        XCTAssertNotNil(CLIInstaller.unstableLocationReason(for: loose))
        let wrongLayout = URL(fileURLWithPath: "/Applications/Searoom.app/MacOS/Searoom")
        XCTAssertNotNil(CLIInstaller.unstableLocationReason(for: wrongLayout))
    }

    func testInstalledBundleLocationIsAccepted() {
        let installed = URL(fileURLWithPath: "/Applications/Searoom.app/Contents/MacOS/Searoom")
        XCTAssertNil(CLIInstaller.unstableLocationReason(for: installed))
        let homeInstalled = URL(fileURLWithPath: "/Users/someone/Applications/Searoom.app/Contents/MacOS/Searoom")
        XCTAssertNil(CLIInstaller.unstableLocationReason(for: homeInstalled))
    }

    func testStateReportsAbsentInstalledAndConflict() throws {
        // Absent before install.
        if case .absent = CLIInstaller.state(homeDirectory: homeDirectory.path, executableURL: executableURL) {} else {
            XCTFail("expected absent")
        }
        // Installed after install.
        _ = install()
        if case .installed = CLIInstaller.state(homeDirectory: homeDirectory.path, executableURL: executableURL) {} else {
            XCTFail("expected installed")
        }
        // Conflict for a foreign link.
        try fileManager.removeItem(at: linkURL)
        let foreign = homeDirectory.appendingPathComponent("foreign")
        try Data("x".utf8).write(to: foreign)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: foreign)
        if case .conflict = CLIInstaller.state(homeDirectory: homeDirectory.path, executableURL: executableURL) {} else {
            XCTFail("expected conflict")
        }
    }

    func testPATHVisibilityIsReportedButShellProfilesAreNeverEdited() throws {
        // Install without PATH containing ~/.local/bin.
        _ = install()
        let profile = homeDirectory.appendingPathComponent(".zprofile")
        let shellInit = homeDirectory.appendingPathComponent(".zshrc")
        XCTAssertFalse(fileManager.fileExists(atPath: profile.path))
        XCTAssertFalse(fileManager.fileExists(atPath: shellInit.path))
        // The advice, when produced, is an exact instruction the user runs
        // themselves.
        let advice = CLIInstaller.pathAdvice(homeDirectory: homeDirectory.path)
        XCTAssertNotNil(advice)
        XCTAssertTrue(advice?.contains("export PATH") ?? false)
        XCTAssertFalse(fileManager.fileExists(atPath: profile.path))
    }

    // MARK: - Linking at launch

    /// Nobody should have to find a checkbox before `searoom` works in a
    /// terminal, so the app links it once at launch.
    func testLaunchLinksTheCommandWhenNothingIsThere() {
        let state = CLIInstaller.linkOnLaunch(
            declined: false,
            homeDirectory: homeDirectory.path,
            executableURL: executableURL
        )
        guard case .installed = state else { return XCTFail("expected the link to be created, got \(state)") }
        XCTAssertTrue(fileManager.fileExists(atPath: linkURL.path))
    }

    /// Turning the command off is a decision, and a relaunch must not undo it.
    func testLaunchRespectsSomeoneWhoTurnedTheCommandOff() {
        let state = CLIInstaller.linkOnLaunch(
            declined: true,
            homeDirectory: homeDirectory.path,
            executableURL: executableURL
        )
        guard case .absent = state else { return XCTFail("expected no link, got \(state)") }
        XCTAssertFalse(fileManager.fileExists(atPath: linkURL.path))
    }

    func testLaunchLeavesSomethingElseAtThePathAlone() throws {
        try fileManager.createDirectory(
            at: CLIInstaller.binDirectory(homeDirectory: homeDirectory.path),
            withIntermediateDirectories: true
        )
        try Data("someone else".utf8).write(to: linkURL)

        let state = CLIInstaller.linkOnLaunch(
            declined: false,
            homeDirectory: homeDirectory.path,
            executableURL: executableURL
        )
        XCTAssertEqual(state, .conflict)
        XCTAssertEqual(try Data(contentsOf: linkURL), Data("someone else".utf8))
    }

    /// Running from a disk image would leave a link pointing at a volume that
    /// disappears on eject.
    func testLaunchDoesNotLinkFromAnUnstableLocation() {
        let mounted = URL(fileURLWithPath: "/Volumes/Searoom/Searoom.app/Contents/MacOS/Searoom")
        let state = CLIInstaller.linkOnLaunch(
            declined: false,
            homeDirectory: homeDirectory.path,
            executableURL: mounted
        )
        guard case .unstableLocation = state else { return XCTFail("expected unstableLocation, got \(state)") }
        XCTAssertFalse(fileManager.fileExists(atPath: linkURL.path))
    }

    // MARK: - A command installed by something else

    /// Homebrew's cask links `searoom` into its own bin directory. Without
    /// this the toggle would report the command missing while it sits working
    /// in the user's shell.
    func testACommandLinkedElsewhereOnPathIsRecognised() throws {
        let brewBin = homeDirectory.appendingPathComponent("brew/bin", isDirectory: true)
        try fileManager.createDirectory(at: brewBin, withIntermediateDirectories: true)
        let brewLink = brewBin.appendingPathComponent("searoom")
        try fileManager.createSymbolicLink(at: brewLink, withDestinationURL: executableURL)

        let found = CLIInstaller.externalCommand(
            on: [brewBin.path, "/usr/bin"],
            excluding: linkURL,
            executableURL: executableURL
        )
        XCTAssertEqual(found, brewLink.path)
    }

    func testACommandOnPathPointingAtADifferentAppIsNotOurs() throws {
        let otherBin = homeDirectory.appendingPathComponent("other/bin", isDirectory: true)
        try fileManager.createDirectory(at: otherBin, withIntermediateDirectories: true)
        let stranger = otherBin.appendingPathComponent("searoom")
        try Data("a different program".utf8).write(to: stranger)

        XCTAssertNil(
            CLIInstaller.externalCommand(
                on: [otherBin.path],
                excluding: linkURL,
                executableURL: executableURL
            )
        )
    }

    /// Our own link must not be mistaken for someone else's.
    func testOurOwnLinkIsNotReportedAsExternal() throws {
        _ = install()
        XCTAssertNil(
            CLIInstaller.externalCommand(
                on: [CLIInstaller.binDirectory(homeDirectory: homeDirectory.path).path],
                excluding: linkURL,
                executableURL: executableURL
            )
        )
    }
}
