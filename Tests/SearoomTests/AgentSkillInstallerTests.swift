import Foundation
import XCTest
@testable import Searoom

final class AgentSkillInstallerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("searoom-agent-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func target(_ id: String) throws -> AgentSkillInstaller.Target {
        try XCTUnwrap(AgentSkillInstaller.targets.first { $0.id == id })
    }

    // MARK: - Paths

    /// Each path was verified against the agent's own documentation, and
    /// against an installed copy where one was available. A wrong directory
    /// here fails silently: the file is written and the agent never reads it.
    func testEachAgentResolvesToItsDocumentedSkillPath() throws {
        let expected = [
            "claude-code": ".claude/skills/interpret-searoom-telemetry/SKILL.md",
            "codex": ".codex/skills/interpret-searoom-telemetry/SKILL.md",
            "cursor": ".cursor/skills/interpret-searoom-telemetry/SKILL.md",
            "opencode": ".config/opencode/skills/interpret-searoom-telemetry/SKILL.md",
        ]
        XCTAssertEqual(Set(expected.keys), Set(AgentSkillInstaller.targets.map(\.id)))
        for agent in AgentSkillInstaller.targets {
            let url = AgentSkillInstaller.skillURL(for: agent, homeDirectory: home.path)
            let relative = url.path.replacingOccurrences(of: home.path + "/", with: "")
            XCTAssertEqual(relative, expected[agent.id], "\(agent.displayName) path")
        }
    }

    /// The directory name is what the agents key on, so it has to match the
    /// skill's own `name:` frontmatter.
    func testTheDirectoryNameMatchesTheSkillFrontmatter() throws {
        let text = String(decoding: try AgentSkillInstaller.bundledSkill(), as: UTF8.self)
        XCTAssertTrue(
            text.contains("name: \(AgentSkillInstaller.skillName)"),
            "the bundled skill must declare name: \(AgentSkillInstaller.skillName)"
        )
    }

    // MARK: - Install, state, remove

    func testInstallWritesTheBundledSkillAndReportsItCurrent() throws {
        let claude = try target("claude-code")
        XCTAssertEqual(AgentSkillInstaller.state(for: claude, homeDirectory: home.path), .absent)

        let outcome = AgentSkillInstaller.install(claude, homeDirectory: home.path)
        XCTAssertTrue(outcome.installed)

        let url = AgentSkillInstaller.skillURL(for: claude, homeDirectory: home.path)
        XCTAssertEqual(try Data(contentsOf: url), try AgentSkillInstaller.bundledSkill())
        XCTAssertEqual(AgentSkillInstaller.state(for: claude, homeDirectory: home.path), .current)
    }

    func testAnEditedOrOlderFileReportsOutdatedRatherThanCurrent() throws {
        let cursor = try target("cursor")
        AgentSkillInstaller.install(cursor, homeDirectory: home.path)
        let url = AgentSkillInstaller.skillURL(for: cursor, homeDirectory: home.path)
        try Data("stale".utf8).write(to: url)
        XCTAssertEqual(AgentSkillInstaller.state(for: cursor, homeDirectory: home.path), .outdated)

        // Installing over it is how the menu offers the update.
        AgentSkillInstaller.install(cursor, homeDirectory: home.path)
        XCTAssertEqual(AgentSkillInstaller.state(for: cursor, homeDirectory: home.path), .current)
    }

    func testRemoveTakesTheDirectoryOnlyWhenItIsEmpty() throws {
        let codex = try target("codex")
        AgentSkillInstaller.install(codex, homeDirectory: home.path)
        let directory = AgentSkillInstaller.skillDirectory(for: codex, homeDirectory: home.path)

        AgentSkillInstaller.remove(codex, homeDirectory: home.path)
        XCTAssertEqual(AgentSkillInstaller.state(for: codex, homeDirectory: home.path), .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        // A skill that grew files beside SKILL.md keeps its directory.
        AgentSkillInstaller.install(codex, homeDirectory: home.path)
        let companion = directory.appendingPathComponent("reference.md")
        try Data("kept".utf8).write(to: companion)
        AgentSkillInstaller.remove(codex, homeDirectory: home.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: companion.path))
    }

    func testRemovingSomethingNeverInstalledIsNotAnError() throws {
        let opencode = try target("opencode")
        let outcome = AgentSkillInstaller.remove(opencode, homeDirectory: home.path)
        XCTAssertFalse(outcome.installed)
        XCTAssertTrue(outcome.message.contains("not installed"))
    }

    func testADirectoryInTheFilesPlaceIsRefusedRatherThanReplaced() throws {
        let claude = try target("claude-code")
        let url = AgentSkillInstaller.skillURL(for: claude, homeDirectory: home.path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let outcome = AgentSkillInstaller.install(claude, homeDirectory: home.path)
        XCTAssertFalse(outcome.installed)
        guard case .blocked = AgentSkillInstaller.state(for: claude, homeDirectory: home.path) else {
            return XCTFail("expected the directory to read as blocked")
        }
    }

    func testInstallAllCoversEveryAgent() throws {
        let outcome = AgentSkillInstaller.installAll(homeDirectory: home.path)
        XCTAssertTrue(outcome.installed)
        for agent in AgentSkillInstaller.targets {
            XCTAssertEqual(
                AgentSkillInstaller.state(for: agent, homeDirectory: home.path),
                .current,
                "\(agent.displayName) should carry the skill"
            )
        }
        XCTAssertTrue(AgentSkillInstaller.anyInstalled(homeDirectory: home.path))
    }

    func testAnyInstalledIsFalseOnACleanHome() {
        XCTAssertFalse(AgentSkillInstaller.anyInstalled(homeDirectory: home.path))
    }
}
