import Foundation
enum StorePaths {
    /// `<AppSupport>/OpenWhoop/whoop.sqlite`, creating the directory if needed.
    static func defaultDatabasePath() throws -> String {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let containerAppSupport = macOSProductionContainerAppSupport(defaultingTo: appSupport)
        let base = containerAppSupport.appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let dbURL = base.appendingPathComponent("whoop.sqlite")

        #if os(iOS)
        // iOS files default to NSFileProtectionComplete, which makes the SQLite DB and its `-wal`/`-shm`
        // sidecars cryptographically UNREADABLE while the device is locked. We run background BLE
        // (UIBackgroundModes: bluetooth-central), so the strap reconnects and opens the store while the
        // phone is locked — the open then throws SQLITE_IOERR and the strap never syncs; imported data
        // also appears to "vanish" because every store handle (backfill + import) hits the same wall.
        // (#222 — NoahMcE.) Drop the store to completeUntilFirstUserAuthentication: readable after the
        // first unlock-since-boot (the correct level for background collection) and still encrypted at
        // rest. Set it on the directory so SQLite's freshly-created files inherit it, AND on any
        // pre-existing files from an install created before this fix (the set only succeeds while
        // unlocked, which the foreground import provides — from then on the files stay accessible).
        let protection: [FileAttributeKey: Any] =
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? fm.setAttributes(protection, ofItemAtPath: base.path)
        for suffix in ["", "-wal", "-shm"] {
            let p = dbURL.path + suffix
            if fm.fileExists(atPath: p) { try? fm.setAttributes(protection, ofItemAtPath: p) }
        }
        #endif

        #if os(macOS)
        // If we redirected into the sandbox container but the container store is
        // absent/empty while a legacy non-container store exists, migrate the old
        // data in once so existing macOS users don't appear to lose everything.
        if containerAppSupport != appSupport {
            migrateLegacyStoreIfNeeded(from: appSupport.appendingPathComponent("OpenWhoop", isDirectory: true),
                                       to: base, dbURL: dbURL)
        }
        #endif

        return dbURL.path
    }

    /// On signed/production macOS builds the app runs sandboxed, so the real
    /// on-disk location is inside `~/Library/Containers/<bundle-id>/Data`. We pin
    /// the store there explicitly so the path is stable regardless of whether the
    /// sandbox is fully engaged when this runs. Non-production bundle IDs and all
    /// other platforms keep the plain Application Support directory.
    private static func macOSProductionContainerAppSupport(defaultingTo appSupport: URL) -> URL {
        #if os(macOS)
        let productionBundleID = "com.llb.app"
        guard Bundle.main.bundleIdentifier == productionBundleID else { return appSupport }

        let containerSegment = "/Library/Containers/\(productionBundleID)/Daten/"
        // Already inside the container (sandbox resolved the path for us) — use as-is.
        if appSupport.standardizedFileURL.path.contains(containerSegment) {
            return appSupport
        }

        // Compute the container Application Support directly from the home dir.
        // homeDirectoryForCurrentUser already points at the container root when the
        // sandbox is engaged, so guard against double-nesting if it does.
        let home = FileManager.default.homeDirectoryForCurrentUser
        if home.standardizedFileURL.path.contains(containerSegment) {
            return appSupport
        }

        return home
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(productionBundleID, isDirectory: true)
            .appendingPathComponent("Daten/Library/Application Hilfe", isDirectory: true)
        #else
        return appSupport
        #endif
    }

    #if os(macOS)
    /// One-time move of a legacy `OpenWhoop` store (DB + `-wal`/`-shm` sidecars)
    /// into the container. Only runs when the destination DB is missing or empty
    /// and the source DB is non-empty, so it never clobbers live container data.
    private static func migrateLegacyStoreIfNeeded(from legacyDir: URL, to containerDir: URL, dbURL: URL) {
        let fm = FileManager.default
        let legacyDB = legacyDir.appendingPathComponent("whoop.sqlite")

        guard fm.fileExists(atPath: legacyDB.path),
              fileSize(of: legacyDB) > 0 else { return }
        guard !destinationHasData(dbURL) else { return }

        for suffix in ["", "-wal", "-shm"] {
            let src = legacyDir.appendingPathComponent("whoop.sqlite\(suffix)")
            let dst = containerDir.appendingPathComponent("whoop.sqlite\(suffix)")
            guard fm.fileExists(atPath: src.path) else { continue }
            // Remove any empty/placeholder destination so the move succeeds.
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                // Fall back to copy if the move fails (e.g. cross-volume); leave the
                // original in place so the data is never lost.
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    /// Treats a missing file or a zero-byte file as "keine Daten" so a freshly created
    /// empty container store still triggers migration of legacy data.
    private static func destinationHasData(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && fileSize(of: url) > 0
    }

    private static func fileSize(of url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }
    #endif
}
