import Foundation

/// The published version manifest at `https://searoom.app/latest.json`.
///
/// Deliberately tiny and first-party: it exists so the check can tell the user a
/// newer version exists without Searoom acquiring an updater, a download path, or
/// anything that runs on its own schedule.
struct UpdateManifest: Decodable, Equatable {
    let version: String
    let url: String
}

enum UpdateCheckOutcome: Equatable {
    case upToDate(current: String)
    case updateAvailable(version: String, url: URL)
    case failed(reason: String)
}

enum UpdateChecker {
    static let manifestURL = URL(string: "https://searoom.app/latest.json")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Compares dot-separated numeric versions. Kept pure and separate from the
    /// request so it is covered by XCTest and the framework-independent self-test.
    ///
    /// String comparison is wrong here: "0.10.0" sorts before "0.9.0" but is newer.
    /// Missing components count as zero, so "0.2" and "0.2.0" are equal.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func numbers(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let left = numbers(candidate)
        let right = numbers(current)
        for index in 0..<max(left.count, right.count) {
            let candidateComponent = index < left.count ? left[index] : 0
            let currentComponent = index < right.count ? right[index] : 0
            if candidateComponent != currentComponent {
                return candidateComponent > currentComponent
            }
        }
        return false
    }

    static func outcome(for manifest: UpdateManifest, current: String) -> UpdateCheckOutcome {
        guard let url = URL(string: manifest.url) else {
            return .failed(reason: "The update manifest contained an unusable link.")
        }
        guard isNewer(manifest.version, than: current) else {
            return .upToDate(current: current)
        }
        return .updateAvailable(version: manifest.version, url: url)
    }

    /// Performs the one network request Searoom ever makes, and only when the user
    /// asks for it. The session is ephemeral and carries no cookies or cache, so
    /// the check leaves nothing behind and cannot become a persistent identifier.
    /// Nothing is downloaded or installed; the caller opens a page in the browser.
    static func check(
        current: String = currentVersion,
        completion: @escaping @Sendable (UpdateCheckOutcome) -> Void
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var request = URLRequest(url: manifestURL)
        // Send a minimal, stable agent rather than the default, which reports the
        // process name, app version, and OS build.
        request.setValue("Searoom", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }

            if let error {
                completion(.failed(reason: error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(.failed(reason: "The update service replied with status \(code)."))
                return
            }
            guard let data, let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
                completion(.failed(reason: "The update manifest could not be read."))
                return
            }
            completion(outcome(for: manifest, current: current))
        }
        task.resume()
    }
}
