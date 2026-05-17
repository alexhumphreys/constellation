import ConstellationCore
import Foundation

// One-stop bag of dependencies for CLI commands. The store path defaults
// to `~/.constellation/constellation.sqlite` but can be overridden via
// `CONSTELLATION_STORE_PATH` so the test suite and the iOS app's
// dogfooding script don't clobber the developer's real data.
struct AppContext {
    let store: Store

    static func standard() async throws -> AppContext {
        let url = storeURL()
        let store = try Store(url: url, sink: OSLogSink())
        return AppContext(store: store)
    }

    static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CONSTELLATION_STORE_PATH"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".constellation", isDirectory: true)
            .appendingPathComponent("constellation.sqlite")
    }
}
