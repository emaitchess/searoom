import Foundation

/// Copies the bundled Agent Skill into the directories coding agents read.
///
/// Every supported agent loads the same `SKILL.md` layout — a directory named
/// for the skill, holding the file — so one bundled document serves all of
/// them and there is nothing per-agent to keep in sync. Installing writes one
/// file per agent and nothing else: no config edits, no registration step, no
/// network.
enum AgentSkillInstaller {
    /// The directory name has to match the skill's `name:` frontmatter, which
    /// is what the agents key on.
    static let skillName = "interpret-searoom-telemetry"

    struct Target: Equatable, Identifiable {
        let id: String
        let displayName: String
        /// Path components under the user's home directory, ending at the
        /// directory that holds skill folders.
        let skillsDirectory: [String]
    }

    /// Paths verified against each agent's own documentation and an installed
    /// copy where one was available. OpenCode also reads `~/.claude/skills`
    /// and `~/.agents/skills`, so installing for Claude Code alone would often
    /// cover it; it gets its own entry anyway, because relying on another
    /// agent being installed is not something a user should have to know.
    static let targets: [Target] = [
        Target(id: "claude-code", displayName: "Claude Code", skillsDirectory: [".claude", "skills"]),
        Target(id: "codex", displayName: "Codex", skillsDirectory: [".codex", "skills"]),
        Target(id: "cursor", displayName: "Cursor", skillsDirectory: [".cursor", "skills"]),
        Target(id: "opencode", displayName: "OpenCode", skillsDirectory: [".config", "opencode", "skills"]),
    ]

    struct Outcome: Equatable {
        let installed: Bool
        let message: String
    }

    enum State: Equatable {
        /// The file is present and byte-identical to the bundled skill.
        case current
        /// Present, but its contents differ: either an older Searoom wrote it
        /// or someone edited it. Never overwritten without being asked.
        case outdated
        case absent
        /// Something is in the way that is not a regular file.
        case blocked(String)
    }

    // MARK: - Paths

    static func skillDirectory(for target: Target, homeDirectory: String = NSHomeDirectory()) -> URL {
        var url = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        for component in target.skillsDirectory {
            url.appendPathComponent(component, isDirectory: true)
        }
        return url.appendingPathComponent(skillName, isDirectory: true)
    }

    static func skillURL(for target: Target, homeDirectory: String = NSHomeDirectory()) -> URL {
        skillDirectory(for: target, homeDirectory: homeDirectory)
            .appendingPathComponent("SKILL.md")
    }

    // MARK: - The bundled document

    static func bundledSkill(bundle: Bundle = .module) throws -> Data {
        // SwiftPM's processed-bundle layout differs across toolchains: some
        // flatten the resource directories into the bundle root, others keep
        // them, so the file is located by name in either shape.
        for subdirectory in [nil, "AgentSkills/interpret-searoom-telemetry"] as [String?] {
            guard let url = bundle.url(
                forResource: "SKILL",
                withExtension: "md",
                subdirectory: subdirectory
            ) else { continue }
            return try Data(contentsOf: url)
        }
        throw CLIError(exitCode: .softwareError, message: "bundled SKILL.md is missing")
    }

    // MARK: - State

    static func state(
        for target: Target,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        bundle: Bundle = .module
    ) -> State {
        let url = skillURL(for: target, homeDirectory: homeDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .absent }
        if isDirectory.boolValue {
            return .blocked("\(url.path) is a directory")
        }
        guard let existing = try? Data(contentsOf: url) else {
            return .blocked("\(url.path) cannot be read")
        }
        guard let bundled = try? bundledSkill(bundle: bundle) else {
            return .blocked("the bundled skill is missing")
        }
        return existing == bundled ? .current : .outdated
    }

    /// True when at least one agent carries the current skill.
    static func anyInstalled(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        bundle: Bundle = .module
    ) -> Bool {
        targets.contains { target in
            switch state(for: target, homeDirectory: homeDirectory, fileManager: fileManager, bundle: bundle) {
            case .current, .outdated: return true
            case .absent, .blocked: return false
            }
        }
    }

    // MARK: - Install and remove

    @discardableResult
    static func install(
        _ target: Target,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        bundle: Bundle = .module
    ) -> Outcome {
        let directory = skillDirectory(for: target, homeDirectory: homeDirectory)
        let url = skillURL(for: target, homeDirectory: homeDirectory)
        let data: Data
        do {
            data = try bundledSkill(bundle: bundle)
        } catch {
            return Outcome(installed: false, message: "cannot read the bundled skill")
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return Outcome(installed: false, message: "\(url.path) is a directory; refusing to replace it")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return Outcome(installed: false, message: "cannot write \(url.path): \(error.localizedDescription)")
        }
        return Outcome(installed: true, message: "installed for \(target.displayName)")
    }

    @discardableResult
    static func remove(
        _ target: Target,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> Outcome {
        let directory = skillDirectory(for: target, homeDirectory: homeDirectory)
        let url = skillURL(for: target, homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: url.path) else {
            return Outcome(installed: false, message: "not installed for \(target.displayName)")
        }
        do {
            try fileManager.removeItem(at: url)
            // Take the directory too, but only when Searoom's file was the
            // only thing in it. A skill that grew references beside it stays.
            if let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path), remaining.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        } catch {
            return Outcome(installed: false, message: "cannot remove \(url.path): \(error.localizedDescription)")
        }
        return Outcome(installed: false, message: "removed from \(target.displayName)")
    }

    /// Installs for every target and summarises what happened, so one action
    /// reports one line rather than four.
    static func installAll(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        bundle: Bundle = .module
    ) -> Outcome {
        var succeeded: [String] = []
        var failed: [String] = []
        for target in targets {
            let outcome = install(target, homeDirectory: homeDirectory, fileManager: fileManager, bundle: bundle)
            if outcome.installed {
                succeeded.append(target.displayName)
            } else {
                failed.append(target.displayName)
            }
        }
        if failed.isEmpty {
            return Outcome(installed: true, message: "installed for \(succeeded.joined(separator: ", "))")
        }
        if succeeded.isEmpty {
            return Outcome(installed: false, message: "could not install for \(failed.joined(separator: ", "))")
        }
        return Outcome(
            installed: true,
            message: "installed for \(succeeded.joined(separator: ", ")); failed for \(failed.joined(separator: ", "))"
        )
    }
}
