//
//  FileProviderShared.swift
//  Shared between the menu-bar app and the File Provider extension.
//
//  A free Personal Team cannot provision App Groups, and `keychain-access-groups`
//  is a restricted entitlement that only a profile-backed signature may carry.
//  So the ad-hoc build uses a loopback-only bridge: the menu-bar app owns the
//  configuration files and serves the minimum needed config/password over
//  127.0.0.1; the sandboxed extension fetches it with its network entitlement.
//  File contents and the metadata cache stay inside the extension container.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum FileProviderShared {

    public static let bridgePort: UInt16 = 47831
    public static let bridgeToken = "tern-loopback-config-v1"
    private static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    public static let domainIdentifier = "com.tern.menubar.fileprovider.offline2"
    public static let keychainService = "com.tern.menubar.fileprovider"
    private static let configService = "com.tern.menubar.fileprovider.config"
    private static let statusService = "com.tern.menubar.fileprovider.status"
    private static let pinnedService = "com.tern.menubar.fileprovider.pinned"
    private static let syncStateService = "com.tern.menubar.fileprovider.syncState"
    private static let extensionBundleIdentifier = "com.tern.menubar.FileProvider"

    private struct Configuration: Codable {
        let serverURL: String
        let username: String
    }

    private struct Status: Codable {
        let pending: Int
        let error: String?
        let lastSync: Double?
    }

    // MARK: - Connection metadata

    public static func saveConfiguration(serverURL: URL, username: String) {
        let value = Configuration(serverURL: serverURL.absoluteString, username: username)
        guard let data = try? JSONEncoder().encode(value) else { return }
        _ = write(data, service: configService, account: "config")
    }

    public static func loadConfiguration() -> (serverURL: URL, username: String)? {
        if isExtension {
            guard let data = bridge(path: "config"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let server = object["serverURL"], let username = object["username"],
                  let url = URL(string: server), !username.isEmpty else { return nil }
            return (url, username)
        }
        guard let data = read(service: configService, account: "config"),
              let value = try? JSONDecoder().decode(Configuration.self, from: data),
              let url = URL(string: value.serverURL),
              !value.username.isEmpty else { return nil }
        return (url, value.username)
    }

    public static func clearConfiguration() {
        delete(service: configService, account: "config")
    }

    // MARK: - Sync enabled / paused

    /// The menu-bar app owns this flag; the extension checks it before any
    /// network request so "断开同步" really stops polling and login attempts.
    public static var isSyncEnabled: Bool {
        if isExtension {
            guard let data = bridge(path: "sync"),
                  let value = String(data: data, encoding: .utf8) else { return true }
            return value != "0"
        }
        guard let data = read(service: syncStateService, account: "enabled"),
              let value = String(data: data, encoding: .utf8) else { return true }
        return value != "0"
    }

    public static func setSyncEnabled(_ enabled: Bool) {
        _ = write(Data((enabled ? "1" : "0").utf8), service: syncStateService, account: "enabled")
    }

    // MARK: - Sync status

    public static func updateSyncStatus(pending: Int, error: String?) {
        let status = Status(pending: pending, error: error, lastSync: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(status) else { return }
        _ = write(data, service: statusService, account: "status")
    }

    public static func syncStatus() -> (pending: Int, error: String?, lastSync: Date?) {
        guard let data = read(service: statusService, account: "status"),
              let status = try? JSONDecoder().decode(Status.self, from: data) else {
            return (0, nil, nil)
        }
        return (status.pending, status.error, status.lastSync.map(Date.init(timeIntervalSince1970:)))
    }

    // MARK: - Keep downloaded

    public static func isPinned(_ itemIdentifier: String) -> Bool {
        pinnedItems().contains(itemIdentifier)
    }

    public static func setPinned(_ pinned: Bool, itemIdentifier: String) {
        var items = Set(pinnedItems())
        if pinned { items.insert(itemIdentifier) } else { items.remove(itemIdentifier) }
        guard let data = try? JSONEncoder().encode(Array(items)) else { return }
        _ = write(data, service: pinnedService, account: "pinned")
    }

    private static func pinnedItems() -> [String] {
        guard let data = read(service: pinnedService, account: "pinned"),
              let items = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return items
    }

    // MARK: - Password

    private static func account(serverURL: URL, username: String) -> String {
        let host = serverURL.host?.lowercased() ?? "unknown-host"
        let port = serverURL.port ?? (serverURL.scheme == "https" ? 443 : 80)
        return "\(username)@\(host):\(port)"
    }

    @discardableResult
    public static func savePassword(_ password: String, serverURL: URL, username: String) -> Bool {
        write(Data(password.utf8), service: keychainService, account: account(serverURL: serverURL, username: username))
    }

    public static func loadPassword(serverURL: URL, username: String) -> String? {
        if isExtension {
            guard let data = bridge(path: "password") else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let data = read(service: keychainService, account: account(serverURL: serverURL, username: username)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func deletePassword(serverURL: URL, username: String) -> Bool {
        delete(service: keychainService, account: account(serverURL: serverURL, username: username))
    }

    // MARK: - Share request bridge

    public static let shareRequestNotification = "com.tern.fileprovider.shareRequest"

    public struct ShareRequest: Codable, Sendable {
        public let nodeId: String
        public let name: String
    }

    public static func notifyShareRequest() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(shareRequestNotification as CFString),
            nil,
            nil,
            true
        )
    }

    /// A Finder action is handed over through the shared directory, so neither
    /// side needs a Keychain ACL that names both code signatures.
    private static let shareRequestService = "com.tern.menubar.fileprovider.shareRequest"

    public static func saveShareRequest(nodeId: String, name: String) {
        guard let data = try? JSONEncoder().encode(ShareRequest(nodeId: nodeId, name: name)) else { return }
        delete(service: shareRequestService, account: "pending")
        _ = write(data, service: shareRequestService, account: "pending")
    }

    /// Read and remove the pending request so one Finder action is handled once.
    public static func takeShareRequest() -> ShareRequest? {
        guard let data = read(service: shareRequestService, account: "pending") else { return nil }
        delete(service: shareRequestService, account: "pending")
        return try? JSONDecoder().decode(ShareRequest.self, from: data)
    }

    // MARK: - Finder Sync action bridge

    public struct FinderAction: Codable, Sendable {
        public let kind: String
        public let paths: [String]
    }

    private static var finderActionFileURL: URL {
        let home = NSHomeDirectory()
        let containerHome = home.contains("/Library/Containers/")
            ? home
            : home + "/Library/Containers/com.tern.menubar.FinderSync/Data"
        return URL(fileURLWithPath: containerHome)
            .appendingPathComponent("Library/Application Support/Tern/finder-action.json")
    }

    public static func saveFinderAction(kind: String, paths: [String]) {
        guard let data = try? JSONEncoder().encode(FinderAction(kind: kind, paths: paths)) else { return }
        let url = finderActionFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func takeFinderAction() -> FinderAction? {
        let url = finderActionFileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? JSONDecoder().decode(FinderAction.self, from: data)
    }

    // MARK: - Shared file store
    //
    // Everything used to be a small Keychain item.  Keychain sharing needs the
    // `keychain-access-groups` entitlement, which AMFI only honours for
    // profile-backed signatures, so a locally signed (ad-hoc) build could never
    // hand credentials to its own extension.  A directory inside the extension
    // container removes that requirement: the menu-bar app is not sandboxed and
    // writes to the same path the extension sees as its home directory.

    /// `~/Library/Application Support/TernShared` (menu-bar app only)
    private static var lastLaunchAttempt: Date?

    /// Sandboxed extension -> loopback config server owned by the menu app.
    /// If the menu app is not running, ask LaunchServices to open it once and
    /// retry briefly. File Provider can be started by the system independently
    /// of the menu-bar app, so this is the fallback for that case.
    private static func bridge(path: String) -> Data? {
        guard isExtension else { return nil }
        if let data = bridgeRequest(path) { return data }

        let now = Date()
        if lastLaunchAttempt == nil || now.timeIntervalSince(lastLaunchAttempt!) > 10 {
            lastLaunchAttempt = now
            #if canImport(AppKit)
            if let url = URL(string: "tern://start") {
                NSWorkspace.shared.open(url)
            }
            #endif
        }

        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.4)
            if let data = bridgeRequest(path) { return data }
        }
        return nil
    }

    private static func bridgeRequest(_ path: String) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(bridgePort)/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        request.setValue(bridgeToken, forHTTPHeaderField: "X-Tern-Token")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = data
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.2)
        return result
    }

    private static var sharedDirectoryURL: URL {
        // The menu-bar app owns this path. The sandboxed extension never reads
        // it directly; it uses the loopback bridge above.
        let pw = getpwuid(getuid())
        let home = pw.map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/TernShared", isDirectory: true)
    }

    private static func fileURL(service: String, account: String) -> URL {
        let safeAccount = String(account.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character
                : "_"
        })
        return sharedDirectoryURL
            .appendingPathComponent("\(service)--\(safeAccount)--\(stableHash(service + "\u{1F}" + account)).bin")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325     // FNV-1a
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func read(service: String, account: String) -> Data? {
        try? Data(contentsOf: fileURL(service: service, account: account))
    }

    @discardableResult
    private static func write(_ data: Data, service: String, account: String) -> Bool {
        let url = fileURL(service: service, account: account)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func delete(service: String, account: String) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL(service: service, account: account))
            return true
        } catch {
            return false
        }
    }
}
