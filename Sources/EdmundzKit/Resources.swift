import Foundation

/// Locates bundled resources: inside the .app, or (for `swift run` / benches) next to the sources.
enum Resources {
    static func url(_ path: String) -> URL? {
        let fm = FileManager.default
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        if let env = ProcessInfo.processInfo.environment["EDMUNDZ_RESOURCES"] { roots.append(URL(fileURLWithPath: env)) }
        roots.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources"))
        // executable-relative: .build/<config>/Edmundz -> repo/Resources
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        roots.append(exe.deletingLastPathComponent().appendingPathComponent("../../Resources").standardizedFileURL)
        for r in roots {
            let u = r.appendingPathComponent(path)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func string(_ path: String) -> String? {
        url(path).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
