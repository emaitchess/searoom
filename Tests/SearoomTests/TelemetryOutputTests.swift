import Foundation
import XCTest
@testable import Searoom

final class TelemetryOutputTests: XCTestCase {
    private let legacyKeys: Set<String> = [
        "timestamp", "cpuUsage", "cpuPressure", "cpuPressureLevel", "loadAverage1m",
        "logicalCPUCount", "memoryTotal", "memoryUsed", "memoryAvailable", "memoryCached",
        "swapUsed", "swapInPerSecond", "swapOutPerSecond", "compressedMemoryBytes",
        "compressionBytesPerSecond", "decompressionBytesPerSecond", "memoryPressure",
        "memoryPressureLevel", "temperatureCelsius", "temperatureSource",
        "thermalPressureLevel", "gpuUsage", "gpuPressure", "gpuPressureLevel",
        "gpuMemoryUsedBytes", "gpuMemoryRecommendedBytes", "gpuMemoryPressure", "fans",
        "networkDownloadPerSecond", "networkUploadPerSecond", "diskReadPerSecond",
        "diskWritePerSecond", "diskCapacityBytes", "diskAvailableBytes", "uptime",
        "processCPUUsage", "processMemoryBytes", "processCount", "batteryPercent",
        "isOnExternalPower", "isLowPowerModeEnabled"
    ]

    private func jsonDictionary(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Legacy dump-sample compatibility

    func testLegacyDumpSampleProjectsExactlyThe41LegacyFields() throws {
        let data = try LegacyDumpSample.makeJSON(from: SystemSample.placeholder)
        let object = try jsonDictionary(data)
        XCTAssertEqual(Set(object.keys), legacyKeys)
        XCTAssertEqual(object.count, 41)
        XCTAssertFalse(object.keys.contains("availability"))
    }

    func testLegacyDumpSampleKeepsIntegerPressureLevelsAndWholeSecondTimestamps() throws {
        let data = try LegacyDumpSample.makeJSON(from: SystemSample.placeholder)
        let object = try jsonDictionary(data)
        XCTAssertEqual(try XCTUnwrap(object["cpuPressureLevel"] as? Int), PressureLevel.unavailable.rawValue)
        XCTAssertEqual(try XCTUnwrap(object["memoryPressureLevel"] as? Int), PressureLevel.unavailable.rawValue)
        let timestamp = try XCTUnwrap(object["timestamp"] as? String)
        XCTAssertTrue(timestamp.hasSuffix("Z"))
        XCTAssertFalse(timestamp.contains("."))
    }

    // MARK: - Version 1 projection

    func testEveryStoredSampleFieldIsRepresentedInVersion1() throws {
        let document = SampleDocumentV1(
            sample: .make(from: SystemSample.placeholder, observerKind: "searoom-cli"),
            intervalSeconds: 2,
            generatedAt: Date(timeIntervalSinceReferenceDate: 0),
            version: CLIVersionInfo(searoomVersion: "9.9.9", buildNumber: "7", macosFloor: "14.0")
        )
        let object = try jsonDictionary(TelemetryOutputV1.encode(document, pretty: false))
        let sample = try XCTUnwrap(object["sample"] as? [String: Any])
        for section in ["cpu", "memory", "thermal", "gpu", "network", "disk", "power", "system", "observer"] {
            XCTAssertNotNil(sample[section], "missing \(section) section")
        }
        XCTAssertEqual(object["document"] as? String, "sample")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["searoomVersion"] as? String, "9.9.9")
        XCTAssertEqual(object["$schema"] as? String, TelemetryOutputV1.schemaURL)
    }

    func testUnavailableReadingsEncodeAsExplicitNull() throws {
        var sample = SystemSample.placeholder
        let data = try JSONEncoder().encode(sample)
        var object = try jsonDictionary(data)
        object["networkDownloadPerSecond"] = 0
        object["networkUploadPerSecond"] = 0
        var availability = try XCTUnwrap(object["availability"] as? [String: Any])
        availability["networkIO"] = "unavailable"
        availability["gpu"] = "unavailable"
        object["availability"] = availability
        sample = try JSONDecoder().decode(SystemSample.self, from: JSONSerialization.data(withJSONObject: object))

        let v1 = TelemetrySampleV1.make(from: sample, observerKind: "searoom-cli")
        let encoded = try jsonDictionary(TelemetryOutputV1.encode(v1, pretty: false))
        let network = try XCTUnwrap(encoded["network"] as? [String: Any])
        XCTAssertTrue(network["downloadBytesPerSecond"] is NSNull)
        XCTAssertTrue(network["uploadBytesPerSecond"] is NSNull)
        let gpu = try XCTUnwrap(encoded["gpu"] as? [String: Any])
        XCTAssertTrue(gpu["usageFraction"] is NSNull)
        XCTAssertEqual(gpu["availability"] as? String, "unavailable")
    }

    func testLegacyUnknownReadingsKeepValuesButAreFlagged() throws {
        let v1 = TelemetrySampleV1.make(from: SystemSample.placeholder, observerKind: "searoom-cli")
        let encoded = try jsonDictionary(TelemetryOutputV1.encode(v1, pretty: false))
        let cpu = try XCTUnwrap(encoded["cpu"] as? [String: Any])
        // Placeholder carries legacyUnknown; the stored value stays visible.
        XCTAssertEqual(cpu["availability"] as? String, "legacyUnknown")
    }

    func testPressureLevelsEncodeAsLowercaseStrings() throws {
        let v1 = TelemetrySampleV1.make(from: SystemSample.placeholder, observerKind: "searoom-cli")
        let encoded = try jsonDictionary(TelemetryOutputV1.encode(v1, pretty: false))
        let thermal = try XCTUnwrap(encoded["thermal"] as? [String: Any])
        XCTAssertEqual(thermal["systemPressureLevel"] as? String, "unavailable")
        let system = try XCTUnwrap(encoded["system"] as? [String: Any])
        XCTAssertEqual(system["overallPressureLevel"] as? String, "unavailable")
    }

    func testDerivedPressureCarriesKindAndFormula() throws {
        let v1 = TelemetrySampleV1.make(from: SystemSample.placeholder, observerKind: "searoom-cli")
        let encoded = try jsonDictionary(TelemetryOutputV1.encode(v1, pretty: false))
        let cpu = try XCTUnwrap(encoded["cpu"] as? [String: Any])
        XCTAssertEqual(cpu["pressureKind"] as? String, "derived")
        XCTAssertEqual(cpu["pressureFormula"] as? String, "max(cpuUsage, loadAverage1m/logicalCPUCount)")
        let gpu = try XCTUnwrap(encoded["gpu"] as? [String: Any])
        XCTAssertEqual(gpu["pressureKind"] as? String, "derived")
    }

    func testObserverKindDistinguishesCLIFromAppHistory() {
        XCTAssertEqual(
            TelemetrySampleV1.make(from: .placeholder, observerKind: "searoom-cli").observer.kind,
            "searoom-cli"
        )
        XCTAssertEqual(
            TelemetrySampleV1.make(from: .placeholder, observerKind: "searoom-app").observer.kind,
            "searoom-app"
        )
    }

    func testNonFiniteValuesCannotProduceInvalidJSON() throws {
        var sample = SystemSample.placeholder
        let data = try PropertyListEncoder().encode(sample)
        var object = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        object["networkDownloadPerSecond"] = Double.infinity
        object["diskWritePerSecond"] = Double.nan
        sample = try PropertyListDecoder().decode(SystemSample.self, from: try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0))

        let v1 = TelemetrySampleV1.make(from: sample, observerKind: "searoom-cli")
        let encoded = try TelemetryOutputV1.encode(v1, pretty: false)
        XCTAssertNoThrow(try jsonDictionary(encoded))
        let network = try XCTUnwrap(try jsonDictionary(encoded)["network"] as? [String: Any])
        XCTAssertTrue(network["downloadBytesPerSecond"] is NSNull)
    }

    func testDatesUseRFC3339WithFractionalSeconds() throws {
        let document = VersionDocumentV1(
            version: CLIVersionInfo(searoomVersion: "1", buildNumber: "1", macosFloor: "14.0"),
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let object = try jsonDictionary(TelemetryOutputV1.encode(document, pretty: false))
        XCTAssertEqual(object["generatedAt"] as? String, "1970-01-01T00:00:00.000Z")
    }

    // MARK: - Bundled schema validation

    private lazy var schema: [String: Any] = {
        let url = Bundle.module.url(forResource: "telemetry-v1.schema", withExtension: "json", subdirectory: "CLI")
            ?? Bundle.module.url(forResource: "telemetry-v1.schema", withExtension: "json", subdirectory: nil)
        let data = try! Data(contentsOf: XCTUnwrap(url))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    /// A focused validator for the schema subset this schema actually uses:
    /// type, required, properties, enum, const, minimum, maximum, items,
    /// allOf, if/then, and local $ref.
    private func validate(_ value: Any, against schemaNode: [String: Any], definitions: [String: Any]) -> [String] {
        var errors: [String] = []
        if let ref = schemaNode["$ref"] as? String, ref.hasPrefix("#/$defs/") {
            let name = String(ref.dropFirst("#/$defs/".count))
            guard let target = definitions[name] as? [String: Any] else {
                return ["unresolvable $ref \(ref)"]
            }
            return validate(value, against: target, definitions: definitions)
        }
        if let allOf = schemaNode["allOf"] as? [[String: Any]] {
            for subSchema in allOf {
                errors += validate(value, against: subSchema, definitions: definitions)
            }
        }
        if let expected = schemaNode["type"] as? String {
            errors += validateType(value, expected: expected, schemaNode: schemaNode, definitions: definitions)
        } else if let expected = schemaNode["type"] as? [Any] {
            let matches = expected.contains { alternative in
                if let name = alternative as? String {
                    return validateType(value, expected: name, schemaNode: schemaNode, definitions: definitions).isEmpty
                        || (name == "null" && value is NSNull)
                }
                return false
            }
            if !matches { errors.append("value \(value) matches none of \(expected)") }
        }
        if let constant = schemaNode["const"] {
            if (constant as? NSObject) != (value as? NSObject) {
                errors.append("expected const \(constant), got \(value)")
            }
        }
        if let allowed = schemaNode["enum"] as? [Any],
           !allowed.contains(where: { ($0 as? NSObject) == (value as? NSObject) }) {
            errors.append("value \(value) not in enum \(allowed)")
        }
        if let number = value as? NSNumber, !(value is NSNull) {
            if let minimum = schemaNode["minimum"] as? Double, number.doubleValue < minimum {
                errors.append("\(number) below minimum \(minimum)")
            }
            if let maximum = schemaNode["maximum"] as? Double, number.doubleValue > maximum {
                errors.append("\(number) above maximum \(maximum)")
            }
        }
        if let dictionary = value as? [String: Any] {
            for required in schemaNode["required"] as? [String] ?? [] where dictionary[required] == nil {
                errors.append("missing required property \(required)")
            }
            if let properties = schemaNode["properties"] as? [String: [String: Any]] {
                for (key, propertySchema) in properties where dictionary[key] != nil {
                    errors += validate(dictionary[key]!, against: propertySchema, definitions: definitions)
                        .map { "\(key): \($0)" }
                }
            }
            if let conditional = schemaNode["if"] as? [String: Any],
               let thenSchema = schemaNode["then"] as? [String: Any] {
                if validate(value, against: conditional, definitions: definitions).isEmpty {
                    errors += validate(value, against: thenSchema, definitions: definitions)
                }
            }
        }
        if let array = value as? [Any], let items = schemaNode["items"] as? [String: Any] {
            for (index, element) in array.enumerated() {
                errors += validate(element, against: items, definitions: definitions)
                    .map { "[\(index)]: \($0)" }
            }
        }
        return errors
    }

    private func validateType(
        _ value: Any,
        expected: String,
        schemaNode: [String: Any],
        definitions: [String: Any]
    ) -> [String] {
        switch expected {
        case "object":
            return value is [String: Any] ? [] : ["expected object, got \(type(of: value))"]
        case "array":
            return value is [Any] ? [] : ["expected array"]
        case "string":
            return value is String ? [] : ["expected string, got \(type(of: value))"]
        case "integer":
            if let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() {
                return number.doubleValue.rounded() == number.doubleValue ? [] : ["expected integer"]
            }
            return ["expected integer"]
        case "number":
            if let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() {
                return []
            }
            return ["expected number"]
        case "boolean":
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return []
            }
            return ["expected boolean"]
        case "null":
            return value is NSNull ? [] : ["expected null"]
        default:
            return ["unknown type \(expected)"]
        }
    }

    private func definitions() throws -> [String: Any] {
        try XCTUnwrap(schema["$defs"] as? [String: Any])
    }

    func testSampleDocumentValidatesAgainstBundledSchema() throws {
        let document = SampleDocumentV1(
            sample: .make(from: SystemSample.placeholder, observerKind: "searoom-cli"),
            intervalSeconds: 2,
            generatedAt: Date(timeIntervalSinceReferenceDate: 0),
            version: .current()
        )
        let object = try jsonDictionary(TelemetryOutputV1.encode(document, pretty: false))
        let errors = validate(object, against: schema, definitions: try definitions())
        XCTAssertTrue(errors.isEmpty, "schema violations: \(errors.prefix(12))")
    }

    func testStatusHistoryAndCapabilitiesValidateAgainstBundledSchema() throws {
        let raw = SystemSample.placeholder
        let derived = CLIRunner.makeDerived(raw)
        let limiting = CLIRunner.makeLimiting(raw)
        let (sustained, context) = CLIRunner.makeSustainedContext(raw: raw, archive: [], now: Date())
        let status = StatusDocumentV1(
            sample: .make(from: raw, observerKind: "searoom-cli"),
            raw: raw,
            limiting: limiting,
            derived: derived,
            sustained: sustained,
            historyContext: context,
            intervalSeconds: 2,
            version: .current(),
            generatedAt: Date()
        )
        let statusObject = try jsonDictionary(TelemetryOutputV1.encode(status, pretty: false))
        let statusErrors = validate(statusObject, against: schema, definitions: try definitions())
        XCTAssertTrue(statusErrors.isEmpty, "status violations: \(statusErrors.prefix(12))")

        let history = HistoryDocumentV1(
            samples: [],
            archive: [],
            archivePath: "/tmp/history.plist",
            version: .current(),
            generatedAt: Date()
        )
        let historyObject = try jsonDictionary(TelemetryOutputV1.encode(history, pretty: false))
        let historyErrors = validate(historyObject, against: schema, definitions: try definitions())
        XCTAssertTrue(historyErrors.isEmpty, "history violations: \(historyErrors.prefix(12))")

        let capabilities = CapabilitiesDocumentV1(
            groups: [],
            intervalSeconds: 2,
            version: .current(),
            generatedAt: Date()
        )
        let capabilitiesObject = try jsonDictionary(TelemetryOutputV1.encode(capabilities, pretty: false))
        let capabilityErrors = validate(capabilitiesObject, against: schema, definitions: try definitions())
        XCTAssertTrue(capabilityErrors.isEmpty, "capabilities violations: \(capabilityErrors.prefix(12))")
    }

    func testHelpCatalogAndMetricCatalogValidateAgainstBundledSchema() throws {
        let help = HelpCatalogDocumentV1(
            catalog: .make(),
            version: .current(),
            generatedAt: Date()
        )
        let helpObject = try jsonDictionary(TelemetryOutputV1.encode(help, pretty: false))
        let helpErrors = validate(helpObject, against: schema, definitions: try definitions())
        XCTAssertTrue(helpErrors.isEmpty, "help violations: \(helpErrors.prefix(12))")

        let metricCatalog = MetricCatalogDocumentV1(
            metrics: try CLIMetricResource.loadDefinitions(),
            version: .current(),
            generatedAt: Date()
        )
        let metricObject = try jsonDictionary(TelemetryOutputV1.encode(metricCatalog, pretty: false))
        let metricErrors = validate(metricObject, against: schema, definitions: try definitions())
        XCTAssertTrue(metricErrors.isEmpty, "metric catalog violations: \(metricErrors.prefix(12))")
    }

    // MARK: - Bundled metric catalogs agree

    func testGeneratedMarkdownContainsEveryCatalogIdentifier() throws {
        // The human catalog is rendered from the bundled JSON, so identifier
        // parity is structural rather than a comparison between two files.
        let definitions = try CLIMetricResource.loadDefinitions()
        let markdown = CLIRunner.catalogMarkdown(definitions)
        for definition in definitions {
            XCTAssertTrue(markdown.contains("## \(definition.id)"), "missing \(definition.id)")
        }
        XCTAssertTrue(markdown.contains("telemetry schema v1"))
        // Every section still carries the canonical bullet fields.
        XCTAssertTrue(markdown.contains("- Path: `"))
        XCTAssertTrue(markdown.contains("- First sample: "))
    }

    func testBundledSchemaIsSelfContainedWithNoRemoteReferences() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "telemetry-v1.schema", withExtension: "json", subdirectory: "CLI")
                ?? Bundle.module.url(forResource: "telemetry-v1.schema", withExtension: "json", subdirectory: nil)
        )
        let body = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(body.contains("http://json-schema.org/draft-07"))
        // The only allowed remote reference is the metaschema identifier.
        XCTAssertTrue(body.contains("https://json-schema.org/draft/2020-12/schema"))
        XCTAssertFalse(body.contains("\"$ref\": \"http"), "schema must not reference remote resources")
        XCTAssertFalse(body.contains("\"$ref\": \"https"), "schema must not reference remote resources")
    }

    // MARK: - Version resolution

    /// Builds a throwaway `Fixture.app` and returns the executable inside it.
    private func makeAppBundle(version: String, build: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let macOS = root.appendingPathComponent("Fixture.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = [
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleIdentifier": "app.searoom.Fixture",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("Fixture.app/Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Searoom")
        try Data().write(to: executable)
        return executable
    }

    func testVersionPrefersTheMainBundleInfoDictionary() {
        let version = CLIVersionInfo.resolve(
            info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"],
            executableURL: nil
        )
        XCTAssertEqual(version.searoomVersion, "1.2.3")
        XCTAssertEqual(version.buildNumber, "42")
        XCTAssertEqual(version.macosFloor, CLIVersionInfo.macosFloorConstant)
    }

    /// The Homebrew and `install-cli` path: the command is a symlink outside
    /// the bundle, so `Bundle.main` carries no Info.plist at all.
    func testVersionResolvesThroughASymlinkOutsideTheBundle() throws {
        let executable = try makeAppBundle(version: "0.5.1", build: "7")
        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + "-searoom")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }

        let version = CLIVersionInfo.resolve(info: nil, executableURL: link)
        XCTAssertEqual(version.searoomVersion, "0.5.1")
        XCTAssertEqual(version.buildNumber, "7")
    }

    func testVersionResolvesFromTheExecutableInsideTheBundle() throws {
        let executable = try makeAppBundle(version: "0.5.1", build: "7")
        let version = CLIVersionInfo.resolve(info: nil, executableURL: executable)
        XCTAssertEqual(version.searoomVersion, "0.5.1")
    }

    /// A partial Info.plist must not report half a version.
    func testVersionIgnoresAnInfoDictionaryMissingTheBuildNumber() throws {
        let executable = try makeAppBundle(version: "0.5.1", build: "7")
        let version = CLIVersionInfo.resolve(
            info: ["CFBundleShortVersionString": "9.9.9"],
            executableURL: executable
        )
        XCTAssertEqual(version.searoomVersion, "0.5.1", "an incomplete dictionary falls through to the bundle")
    }

    func testVersionFallsBackToThePlaceholderWithNoEnclosingBundle() throws {
        let loose = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Searoom")
        let version = CLIVersionInfo.resolve(info: nil, executableURL: loose)
        XCTAssertEqual(version.searoomVersion, "0.0.0")
        XCTAssertEqual(version.buildNumber, "0")
    }

    func testCLIMarkdownRendersSingleDefinition() throws {
        let definition = try XCTUnwrap(try CLIMetricResource.loadDefinitions().first)
        let markdown = CLIRunner.markdown(definition)
        XCTAssertTrue(markdown.contains("### \(definition.id)"))
        XCTAssertTrue(markdown.contains(definition.unit))
    }
}
