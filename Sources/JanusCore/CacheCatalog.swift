import Foundation

/// A directory Janus is allowed to clear.
///
/// Everything in the catalogue is a cache in the strict sense: deleting it costs
/// time on the next run and nothing else. Anything that could hold work worth
/// keeping does not belong here.
public struct CacheEntry: Identifiable, Hashable {
    public let id: String
    public let name: String
    /// What it is and what clearing it costs, written for someone who has never
    /// heard of the tool that created it.
    public let note: String
    /// Always relative to the home directory. Absolute paths are not accepted,
    /// which keeps every target inside the one place clearing is allowed.
    public let path: String
    /// Bundle identifier of the app that owns the directory, when one does.
    public let ownerBundleID: String?
    /// True when clearing it under a running owner is harmless, as with staging
    /// areas an app reads only at update time, rather than caches it holds open.
    public let clearableWhileRunning: Bool

    public init(id: String,
                name: String,
                note: String,
                path: String,
                ownerBundleID: String? = nil,
                clearableWhileRunning: Bool = true) {
        self.id = id
        self.name = name
        self.note = note
        self.path = path
        self.ownerBundleID = ownerBundleID
        self.clearableWhileRunning = clearableWhileRunning
    }

    public func url(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(path)
    }

    public var displayPath: String { "~/" + path }
}

public extension CacheEntry {

    /// The full list. Entries that do not exist on this Mac are filtered out when
    /// scanning, so listing something most people will not have costs nothing.
    static let catalog: [CacheEntry] = developerTools + applications

    static let developerTools: [CacheEntry] = [
        CacheEntry(id: "npm", name: "npm cache",
                   note: "Downloaded packages. npm refetches what it needs.",
                   path: ".npm"),
        CacheEntry(id: "pnpm", name: "pnpm store",
                   note: "Shared package store. `pnpm store prune` is the gentler option. This clears all of it.",
                   path: "Library/pnpm/store"),
        CacheEntry(id: "yarn", name: "Yarn cache",
                   note: "Downloaded packages, refetched on the next install.",
                   path: "Library/Caches/Yarn"),
        CacheEntry(id: "bun", name: "Bun install cache",
                   note: "Package cache for Bun installs.",
                   path: ".bun/install/cache"),
        CacheEntry(id: "deno", name: "Deno cache",
                   note: "Fetched modules and compiled output.",
                   path: "Library/Caches/deno"),
        CacheEntry(id: "node-gyp", name: "node-gyp headers",
                   note: "Node header archives kept for building native modules.",
                   path: "Library/Caches/node-gyp"),
        CacheEntry(id: "go-build", name: "Go build cache",
                   note: "Compiled objects. The next build after clearing is slower.",
                   path: "Library/Caches/go-build"),
        CacheEntry(id: "go-mod", name: "Go module cache",
                   note: "Downloaded module sources.",
                   path: "go/pkg/mod"),
        CacheEntry(id: "pip", name: "pip cache",
                   note: "Downloaded Python wheels.",
                   path: "Library/Caches/pip"),
        CacheEntry(id: "uv", name: "uv cache",
                   note: "Python packages and built wheels.",
                   path: ".cache/uv"),
        CacheEntry(id: "homebrew", name: "Homebrew downloads",
                   note: "Installers for packages that are already installed.",
                   path: "Library/Caches/Homebrew"),
        CacheEntry(id: "cocoapods", name: "CocoaPods cache",
                   note: "Downloaded pod sources and specs.",
                   path: "Library/Caches/CocoaPods"),
        CacheEntry(id: "gradle", name: "Gradle caches",
                   note: "Downloaded dependencies and build output.",
                   path: ".gradle/caches"),
        CacheEntry(id: "playwright", name: "Playwright browsers",
                   note: "Browser binaries, redownloaded on the next test run.",
                   path: "Library/Caches/ms-playwright"),
        CacheEntry(id: "puppeteer", name: "Puppeteer browsers",
                   note: "Chromium builds downloaded by Puppeteer.",
                   path: ".cache/puppeteer"),
        CacheEntry(id: "prisma", name: "Prisma engines",
                   note: "Query engine binaries, redownloaded when needed.",
                   path: ".cache/prisma"),
        CacheEntry(id: "derived-data", name: "Xcode derived data",
                   note: "Build products and indexes. Xcode rebuilds them; the next build is a long one.",
                   path: "Library/Developer/Xcode/DerivedData",
                   ownerBundleID: "com.apple.dt.Xcode",
                   clearableWhileRunning: false),
        CacheEntry(id: "swiftpm", name: "Swift package cache",
                   note: "Checked-out package dependencies.",
                   path: "Library/Caches/org.swift.swiftpm")
    ]

    static let applications: [CacheEntry] = [
        CacheEntry(id: "chrome", name: "Chrome cache",
                   note: "Cached pages and images. History, passwords and profiles live elsewhere and are untouched.",
                   path: "Library/Caches/Google",
                   ownerBundleID: "com.google.Chrome",
                   clearableWhileRunning: false),
        CacheEntry(id: "vscode-data", name: "VS Code compiled cache",
                   note: "Bytecode rebuilt on the next launch.",
                   path: "Library/Application Support/Code/CachedData",
                   ownerBundleID: "com.microsoft.VSCode",
                   clearableWhileRunning: false),
        CacheEntry(id: "vscode-vsix", name: "VS Code extension downloads",
                   note: "Installers for extensions that are already installed.",
                   path: "Library/Application Support/Code/CachedExtensionVSIXs",
                   ownerBundleID: "com.microsoft.VSCode",
                   clearableWhileRunning: false),
        CacheEntry(id: "vscode-net", name: "VS Code network cache",
                   note: "HTTP cache belonging to the editor's browser engine.",
                   path: "Library/Application Support/Code/Cache",
                   ownerBundleID: "com.microsoft.VSCode",
                   clearableWhileRunning: false),
        CacheEntry(id: "vscode-logs", name: "VS Code logs",
                   note: "Log files from previous editing sessions.",
                   path: "Library/Application Support/Code/logs",
                   ownerBundleID: "com.microsoft.VSCode",
                   clearableWhileRunning: false),
        CacheEntry(id: "slack-updates", name: "Slack update staging",
                   note: "Downloaded updates, read only while Slack updates itself.",
                   path: "Library/Caches/com.tinyspeck.slackmacgap.ShipIt",
                   ownerBundleID: "com.tinyspeck.slackmacgap",
                   clearableWhileRunning: true)
    ]
}
