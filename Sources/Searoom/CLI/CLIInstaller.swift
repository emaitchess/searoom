import Foundation

/// Rootless installation of the lowercase `searoom` command. Creates exactly
/// one symlink at `~/.local/bin/searoom` pointing at the installed app
/// executable. It never edits shell profiles, never writes system bin
/// directories, and never requests privileges.
enum CLIInstaller {
    struct Outcome: Equatable {
        let exitCode: Int32
        let message: String
    }

    // MARK: - Paths

    static func binDirectory(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    static func linkURL(homeDirectory: String) -> URL {
        binDirectory(homeDirectory: homeDirectory).appendingPathComponent("searoom")
    }

    /// The executable that should own the link. Injectable for tests.
    static func currentExecutableURL() -> URL {
        if let url = Bundle.main.executableURL {
            return url
        }
        return URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    }

    // MARK: - Stability policy

    /// A reason string when the executable's location is unsuitable for a
    /// permanent symlink: mounted disk images, App Translocation, or anything
    /// outside an .app bundle.
    static func unstableLocationReason(for url: URL) -> String? {
        let standardized = url.standardizedFileURL.path
        if standardized.hasPrefix("/Volumes/") {
            return "the app is running from a mounted volume; install Searoom to /Applications first"
        }
        if standardized.contains("AppTranslocation") {
            return "the app is running from App Translocation; move Searoom to /Applications and relaunch it"
        }
        let components = standardized.split(separator: "/").map(String.init)
        guard components.contains(".app") || components.contains(where: { $0.hasSuffix(".app") }),
              let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }),
              components.count > appIndex + 3,
              components[appIndex + 1] == "Contents",
              components[appIndex + 2] == "MacOS" else {
            return "the executable is not inside an installed .app bundle"
        }
        return nil
    }

    // MARK: - Install

    static func install(
        homeDirectory: String = NSHomeDirectory(),
        executableURL: URL = currentExecutableURL(),
        fileManager: FileManager = .default
    ) -> Outcome {
        if let reason = unstableLocationReason(for: executableURL) {
            return Outcome(exitCode: 65, message: reason)
        }
        let target = executableURL.standardizedFileURL.path
        let link = linkURL(homeDirectory: homeDirectory)
        let binDirectory = binDirectory(homeDirectory: homeDirectory)

        do {
            if fileManager.fileExists(atPath: link.path) {
                if let existing = existingLinkTarget(link, fileManager: fileManager) {
                    if existing == target {
                        return Outcome(exitCode: 0, message: "\(link.path) already points at \(target)")
                    }
                    return Outcome(
                        exitCode: 65,
                        message: "\(link.path) exists but points at \(existing); remove it before installing"
                    )
                }
                return Outcome(
                    exitCode: 65,
                    message: "\(link.path) exists and is not a symlink; refusing to overwrite it"
                )
            }
            try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: executableURL.standardizedFileURL)
        } catch {
            return Outcome(exitCode: 74, message: "cannot install \(link.path): \(error.localizedDescription)")
        }
        var message = "created \(link.path) -> \(target)"
        if let pathAdvice = pathAdvice(homeDirectory: homeDirectory) {
            message += "\n\(pathAdvice)"
        }
        return Outcome(exitCode: 0, message: message)
    }

    // MARK: - Uninstall

    static func uninstall(
        homeDirectory: String = NSHomeDirectory(),
        executableURL: URL = currentExecutableURL(),
        fileManager: FileManager = .default
    ) -> Outcome {
        let link = linkURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: link.path) else {
            return Outcome(exitCode: 0, message: "\(link.path) is not installed")
        }
        guard let existing = existingLinkTarget(link, fileManager: fileManager) else {
            return Outcome(
                exitCode: 65,
                message: "\(link.path) is not a symlink; refusing to remove it"
            )
        }
        let target = executableURL.standardizedFileURL.path
        guard existing == target else {
            return Outcome(
                exitCode: 65,
                message: "\(link.path) points at \(existing), not this app; refusing to remove it"
            )
        }
        do {
            try fileManager.removeItem(at: link)
        } catch {
            return Outcome(exitCode: 74, message: "cannot remove \(link.path): \(error.localizedDescription)")
        }
        return Outcome(exitCode: 0, message: "removed \(link.path)")
    }

    /// The resolved destination of `link` when it truly is a symlink; nil for
    /// regular files and directories.
    private static func existingLinkTarget(
        _ link: URL,
        fileManager: FileManager
    ) -> String? {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else {
            return nil
        }
        return link.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - PATH visibility

    /// An exact instruction when `~/.local/bin` is not on PATH. Shell profiles
    /// are never edited; the user runs one command themselves.
    static func pathAdvice(homeDirectory: String) -> String? {
        let binDirectory = binDirectory(homeDirectory: homeDirectory).path
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard !searchPaths.contains(binDirectory) else { return nil }
        return """
        \(binDirectory) is not on PATH. Add it with:
          echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile
        then open a new terminal, or run Searoom directly at:
          \(currentExecutableURL().standardizedFileURL.path)
        """
    }

    // MARK: - State reporting (read-only, for the Settings control)

    enum InstallState: Equatable {
        /// A Searoom-owned link exists and points at the app.
        case installed(pathVisible: Bool)
        /// Nothing at the link path.
        case absent(pathVisible: Bool)
        /// A regular file or an unrelated symlink occupies the link path.
        case conflict
        /// The app itself is running from a location that must not be linked.
        case unstableLocation(reason: String)
    }

    /// Inspects the install state without changing anything. The Settings
    /// control calls this to report installed, conflict, unavailable-path, and
    /// PATH-not-visible states.
    static func state(
        homeDirectory: String = NSHomeDirectory(),
        executableURL: URL = currentExecutableURL(),
        fileManager: FileManager = .default
    ) -> InstallState {
        if let reason = unstableLocationReason(for: executableURL) {
            return .unstableLocation(reason: reason)
        }
        let link = linkURL(homeDirectory: homeDirectory)
        let pathVisible = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .contains(binDirectory(homeDirectory: homeDirectory).path)
        guard fileManager.fileExists(atPath: link.path) else {
            return .absent(pathVisible: pathVisible)
        }
        guard let existing = existingLinkTarget(link, fileManager: fileManager) else {
            return .conflict
        }
        guard existing == executableURL.standardizedFileURL.path else {
            return .conflict
        }
        return .installed(pathVisible: pathVisible)
    }

    // MARK: - Command entry points

    static func runInstall(
        homeDirectory: String = NSHomeDirectory(),
        executableURL: URL = currentExecutableURL()
    ) -> Int32 {
        let outcome = install(homeDirectory: homeDirectory, executableURL: executableURL)
        FileHandle.standardOutput.write(Data(outcome.message.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
        return outcome.exitCode
    }

    static func runUninstall(
        homeDirectory: String = NSHomeDirectory(),
        executableURL: URL = currentExecutableURL()
    ) -> Int32 {
        let outcome = uninstall(homeDirectory: homeDirectory, executableURL: executableURL)
        FileHandle.standardOutput.write(Data(outcome.message.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
        return outcome.exitCode
    }
}
