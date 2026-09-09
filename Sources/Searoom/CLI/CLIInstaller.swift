import Foundation

/// Rootless installation of the lowercase `searoom` command. Creates one
/// symlink at `~/.local/bin/searoom` pointing at the installed app executable,
/// and, when that directory is not already reachable, one clearly marked block
/// in the user's shell profile that puts it on PATH. It never writes system
/// bin directories and never requests privileges.
///
/// The profile block exists because nothing else reaches a stock PATH without
/// privileges. macOS ships `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, and
/// both `/usr/local/bin` and `/etc/paths.d` are root-owned, so a command a user
/// can install without authorization has to arrive through their own profile.
/// Both edits are reversible from the same toggle that made them.
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
        /// Something else on PATH already resolves to this app — Homebrew's
        /// `bin` link is the usual one. The command works and is not ours to
        /// remove, so the toggle reports it rather than offering to undo it.
        case managedExternally(path: String)
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
        let searchPaths = commandSearchPaths()
        let pathVisible = binDirectoryOnPath(homeDirectory: homeDirectory, fileManager: fileManager)
        guard fileManager.fileExists(atPath: link.path) else {
            if let external = externalCommand(
                on: searchPaths,
                excluding: link,
                executableURL: executableURL,
                fileManager: fileManager
            ) {
                return .managedExternally(path: external)
            }
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

    /// Where to look for a command someone else installed. A GUI app launched
    /// from Finder inherits a minimal PATH that has never seen a shell profile,
    /// so the package managers' own directories are checked by name as well;
    /// without that, a Homebrew user would be told the command was missing and
    /// handed a second, redundant link in `~/.local/bin`.
    static func commandSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        let wellKnown = ["/opt/homebrew/bin", "/usr/local/bin"]
        return fromPath + wellKnown.filter { !fromPath.contains($0) }
    }

    /// A `searoom` somewhere on PATH that resolves to this same executable but
    /// is not our link. Homebrew's cask creates exactly this, and without the
    /// check a Homebrew user would be told the command is not installed while
    /// it sits working in their shell.
    static func externalCommand(
        on searchPaths: [String],
        excluding link: URL,
        executableURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let target = executableURL.resolvingSymlinksInPath().standardizedFileURL.path
        for directory in searchPaths where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("searoom")
            guard candidate.standardizedFileURL != link.standardizedFileURL,
                  fileManager.fileExists(atPath: candidate.path) else { continue }
            if candidate.resolvingSymlinksInPath().standardizedFileURL.path == target {
                return candidate.path
            }
        }
        return nil
    }

    // MARK: - Shell profile

    /// The files Searoom will write to. `.zprofile` is created when absent
    /// because zsh is the macOS default; `.bash_profile` is only touched when
    /// the user already has one, so a bash file is never conjured for someone
    /// who does not use bash.
    static func profileURLs(homeDirectory: String, fileManager: FileManager = .default) -> [URL] {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        var urls = [home.appendingPathComponent(".zprofile")]
        let bashProfile = home.appendingPathComponent(".bash_profile")
        if fileManager.fileExists(atPath: bashProfile.path) {
            urls.append(bashProfile)
        }
        return urls
    }

    /// The files Searoom will read before deciding to write one. Deliberately
    /// wider than the write set: people set PATH in `.zshrc` far more often
    /// than in `.zprofile`, and appending a second entry to someone who has
    /// already configured this is exactly the sort of uninvited edit that
    /// makes a tool untrustworthy.
    static func inspectedProfileURLs(homeDirectory: String) -> [URL] {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        return [".zprofile", ".zshrc", ".zshenv", ".bash_profile", ".bashrc", ".profile"]
            .map(home.appendingPathComponent)
    }

    static let profileBlockStart = "# >>> searoom >>>"
    static let profileBlockEnd = "# <<< searoom <<<"

    static var profileBlock: String {
        """
        \(profileBlockStart)
        # Puts the searoom command on PATH. Written by Searoom, and removed
        # again when the command is turned off in Searoom's settings.
        export PATH="$HOME/.local/bin:$PATH"
        \(profileBlockEnd)
        """
    }

    /// True when the command's directory will already be found, either in this
    /// process's PATH or because a login file mentions it.
    ///
    /// The login files matter more than the environment here. A GUI app
    /// launched from Finder inherits a minimal PATH that never reflects the
    /// user's shell configuration, so trusting the environment alone would
    /// append a redundant block to the profile of everyone who had already set
    /// this up by hand.
    static func binDirectoryOnPath(
        homeDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        let directory = binDirectory(homeDirectory: homeDirectory).path
        let searchPaths = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        if searchPaths.contains(directory) { return true }
        for url in inspectedProfileURLs(homeDirectory: homeDirectory) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains(".local/bin") { return true }
        }
        return false
    }

    /// Appends the block when, and only when, the directory is not already
    /// reachable. Returns the files it changed.
    @discardableResult
    static func addBinDirectoryToPath(
        homeDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard !binDirectoryOnPath(
            homeDirectory: homeDirectory,
            environment: environment,
            fileManager: fileManager
        ) else { return [] }

        var changed: [URL] = []
        for url in profileURLs(homeDirectory: homeDirectory, fileManager: fileManager) {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard !existing.contains(profileBlockStart) else { continue }
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            let updated = existing + separator + "\n" + profileBlock + "\n"
            guard (try? updated.write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
            changed.append(url)
        }
        return changed
    }

    /// Removes the block, and only the block, from every login file that has
    /// one. Anything the user wrote around it is left exactly as it was.
    @discardableResult
    static func removeBinDirectoryFromPath(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [URL] {
        var changed: [URL] = []
        for url in inspectedProfileURLs(homeDirectory: homeDirectory) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(profileBlockStart) else { continue }
            var kept: [String] = []
            var inside = false
            for line in text.components(separatedBy: "\n") {
                if line.trimmingCharacters(in: .whitespaces) == profileBlockStart {
                    inside = true
                    // Drop the blank line the block was padded with.
                    if kept.last?.isEmpty == true { kept.removeLast() }
                    continue
                }
                if inside {
                    if line.trimmingCharacters(in: .whitespaces) == profileBlockEnd { inside = false }
                    continue
                }
                kept.append(line)
            }
            let updated = kept.joined(separator: "\n")
            guard (try? updated.write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
            changed.append(url)
        }
        return changed
    }

    // MARK: - First launch

    /// Links the command at launch so it is there the first time someone opens
    /// a terminal, rather than waiting to be found in Settings. Silent by
    /// design: it creates one symlink in the user's own directory, and does
    /// nothing at all when the command already works, when something is in the
    /// way, when the app is running from a disk image, or when the user has
    /// turned it off.
    @discardableResult
    static func linkOnLaunch(
        declined: Bool,
        homeDirectory: String = NSHomeDirectory(),
        executableURL: URL = currentExecutableURL(),
        fileManager: FileManager = .default
    ) -> InstallState {
        let current = state(
            homeDirectory: homeDirectory,
            executableURL: executableURL,
            fileManager: fileManager
        )
        guard !declined, case .absent = current else { return current }
        let outcome = install(
            homeDirectory: homeDirectory,
            executableURL: executableURL,
            fileManager: fileManager
        )
        // A link nothing can find is not an installed command, so the PATH
        // entry is part of the same step rather than advice printed after it.
        if outcome.exitCode == 0 {
            addBinDirectoryToPath(homeDirectory: homeDirectory, fileManager: fileManager)
        }
        return state(
            homeDirectory: homeDirectory,
            executableURL: executableURL,
            fileManager: fileManager
        )
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
