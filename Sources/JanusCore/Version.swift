import Foundation

/// The running version, read from the bundle that `build.sh` assembles.
///
/// A single source of truth lives in the `VERSION` file at the root of the
/// repository; the build script copies it into `Info.plist`, and this reads it
/// back out. Builds run straight from `swift run` have no bundle to read.
public enum Build {

    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    public static var displayVersion: String { "v" + version }
}
