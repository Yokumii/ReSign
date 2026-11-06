import Foundation

struct LibraryStore {
    let root: URL
    var ipaDirectory: URL { root.appendingPathComponent("IPAs", isDirectory: true) }
    var workDirectory: URL { root.appendingPathComponent("Work", isDirectory: true) }
    private var iconDirectory: URL { root.appendingPathComponent("Icons", isDirectory: true) }
    private var libraryURL: URL { root.appendingPathComponent("library.json") }

    init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            .appendingPathComponent("io.resign.mac", isDirectory: true)
        for directory in [self.root, ipaDirectory, workDirectory, iconDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return Library() }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryURL))
        guard library.schemaVersion == 1 else { throw ReSignError("不支持的应用资料版本。") }
        return library
    }

    func save(_ library: Library) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: libraryURL, options: .atomic)
    }

    func sourceURL(for app: ManagedApp) throws -> URL {
        guard app.ipaFilename == URL(fileURLWithPath: app.ipaFilename).lastPathComponent,
              app.ipaFilename.hasSuffix(".ipa") else { throw ReSignError("IPA 缓存路径无效。") }
        return ipaDirectory.appendingPathComponent(app.ipaFilename)
    }

    func iconURL(for app: ManagedApp) throws -> URL {
        let source = try sourceURL(for: app)
        return iconDirectory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".png")
    }
}
