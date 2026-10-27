//
//  AppModel.swift
//  Tern (Tern) macOS menu-bar client
//
//  Owns the File Provider lifecycle and the settings/keychain state.  The
//  client no longer mounts WebDAV: Finder access goes exclusively through the
//  replicated File Provider extension, and a long-poll watcher keeps it in
//  sync with changes made by the web UI or other clients.
//

import Foundation
import AppKit
import Combine
import SwiftUI

@MainActor
public final class AppModel: ObservableObject {

    public static let shared = AppModel()

    @Published public private(set) var fileProviderEnabled = false
    @Published public private(set) var syncEnabled = true
    @Published public private(set) var credentialsReady = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSyncText = "尚未同步"

    public let settings: SettingsStore

    private let fileProviderWatcher = FileProviderWatcher()
    private var started = false
    private var cachedPassword: String?
    private var cachedCredentialKey: String?
    private var syncClockTimer: Timer?
    private var lastCheckAt: Date?

    private init(settings: SettingsStore = SettingsStore.shared) {
        self.settings = settings
    }

    // MARK: - Derived UI strings

    public var menuBarSymbol: String {
        fileProviderEnabled ? "cloud.fill" : "cloud"
    }

    public var statusHeadline: String {
        if FileProviderShared.loadConfiguration() == nil {
            return "尚未配置"
        }
        if !syncEnabled { return "同步已暂停" }
        return fileProviderEnabled ? "Tern File Provider" : "已配置，等待启用"
    }

    public var statusDetail: String? {
        if let lastError, !lastError.isEmpty { return lastError }
        guard FileProviderShared.loadConfiguration() != nil else {
            return "打开设置，填写服务器和密码"
        }
        return "Finder → 位置 → Tern"
    }

    public var serverURLText: String {
        (try? settings.validatedServerURL())?.absoluteString ?? settings.serverURLText
    }

    public var fileProviderStatus: String {
        if FileProviderShared.loadConfiguration() == nil { return "未配置" }
        return fileProviderEnabled ? "已注册" : "已配置"
    }

    public var syncStatusText: String {
        let sync = FileProviderShared.syncStatus()
        if let error = sync.error, !error.isEmpty { return error }
        if sync.pending > 0 { return "待上传 \(sync.pending) 项" }
        return sync.lastSync == nil ? "等待首次同步" : "已同步"
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        CDLog.info("app: start \(TernInfo.versionDescription) bundle=\(Bundle.main.bundleURL.path)")

        LaunchAgentManager.repairIfInstalled(appURL: Bundle.main.bundleURL)
        settings.connectAtLogin = LaunchAgentManager.isInstalled()

        refreshCredentialState()
        fileProviderEnabled = FileProviderShared.loadConfiguration() != nil
        syncEnabled = FileProviderShared.isSyncEnabled
        lastCheckAt = FileProviderShared.syncStatus().lastSync
        configureWatcher()
        if fileProviderEnabled && syncEnabled {
            fileProviderWatcher.start()
        }
        ShareRequestHandler.shared.start()
        refreshLastSyncText()
        syncClockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLastSyncText() }
        }
        Task { await UpdateChecker.checkAndNotify() }

        if FileProviderShared.loadConfiguration() != nil {
            Task { [weak self] in
                guard self != nil else { return }
                do {
                    try await FileProviderBridge.addDomain()
                    CDLog.info("fileprovider: domain registered on launch")
                } catch {
                    CDLog.warn("fileprovider: launch registration failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func shutdown() {
        fileProviderWatcher.stop()
        ShareRequestHandler.shared.stop()
        syncClockTimer?.invalidate()
        syncClockTimer = nil
        CDLog.info("app: shutdown")
    }

    private func configureWatcher() {
        fileProviderWatcher.onCheck = { [weak self] in
            Task { @MainActor in
                self?.lastCheckAt = Date()
                self?.refreshLastSyncText()
            }
        }
    }

    private func refreshLastSyncText() {
        let sharedLast = FileProviderShared.syncStatus().lastSync
        let last: Date?
        if let lastCheckAt, let sharedLast {
            last = max(lastCheckAt, sharedLast)
        } else {
            last = lastCheckAt ?? sharedLast
        }
        lastSyncText = AppModel.relativeTime(last)
    }

    private static func relativeTime(_ date: Date?) -> String {
        guard let date else { return "尚未同步" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(max(1, seconds))秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前" }
        let days = hours / 24
        if days < 7 { return "\(days)天前" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)周前" }
        let months = days / 30
        if months < 12 { return "\(months)月前" }
        return "\(days / 365)年前"
    }

    // MARK: - Settings

    /// Persist the server/user/password, the shared File Provider copy and the
    /// login item.  Returns a human-readable error, or nil on success.
    @discardableResult
    public func applySettings(serverURLText: String,
                              username: String,
                              password: String?,
                              connectAtLogin: Bool) -> String? {
        do {
            let url = try SettingsStore.normalize(serverText: serverURLText)
            let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedUsername.isEmpty else {
                return "请填写用户名（与 Tern 网页登录账号相同）。"
            }
            if let password, !password.isEmpty {
                try KeychainStore.savePassword(password, serverURL: url, username: trimmedUsername)
                cachedPassword = password
                cachedCredentialKey = KeychainStore.account(serverURL: url, username: trimmedUsername)
                credentialsReady = true
            } else if storedPassword(for: url, username: trimmedUsername) == nil {
                return "设置未保存：钥匙串中没有密码，请填写密码后重试。"
            }

            settings.serverURLText = url.absoluteString
            settings.username = trimmedUsername

            // The extension is a separate process. Keep the shared Keychain
            // copy in sync whenever settings are saved.
            FileProviderShared.saveConfiguration(serverURL: url, username: trimmedUsername)
            if let password, !password.isEmpty {
                _ = FileProviderShared.savePassword(password, serverURL: url, username: trimmedUsername)
            }

            if connectAtLogin != LaunchAgentManager.isInstalled() {
                if connectAtLogin {
                    try LaunchAgentManager.install(appURL: Bundle.main.bundleURL)
                } else {
                    LaunchAgentManager.uninstall()
                }
            }
            settings.connectAtLogin = LaunchAgentManager.isInstalled()

            fileProviderEnabled = FileProviderShared.loadConfiguration() != nil
            if syncEnabled && fileProviderEnabled {
                fileProviderWatcher.start()
            }
            refreshCredentialState()
            lastError = nil
            CDLog.info("settings: saved url=\(url.absoluteString) user=\(trimmedUsername) loginItem=\(settings.connectAtLogin)")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Register the File Provider domain and start the watcher.  Credentials
    /// must already be present in the standard and shared Keychains.
    public func enableFileProvider() async -> String {
        guard let url = (try? settings.validatedServerURL()) else {
            return "❌ 请先填写有效的服务器地址。"
        }
        let username = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return "❌ 请先填写用户名。"
        }
        guard let password = storedPassword(for: url, username: username), !password.isEmpty else {
            return "❌ 请先保存密码。"
        }

        FileProviderShared.saveConfiguration(serverURL: url, username: username)
        guard FileProviderShared.loadConfiguration() != nil else {
            return "❌ 无法写入共享 Keychain。请确认应用已使用 Keychain Sharing 签名。"
        }
        guard FileProviderShared.savePassword(password, serverURL: url, username: username) else {
            return "❌ 无法把密码写入共享钥匙串。请确认应用已使用 Keychain Sharing 签名。"
        }

        do {
            try await FileProviderBridge.addDomain()
            FileProviderShared.setSyncEnabled(true)
            syncEnabled = true
            fileProviderWatcher.start()
            fileProviderEnabled = true
            lastError = nil
            return "✅ 已添加 Tern 到 Finder 位置。若系统提示未启用，请在 系统设置 → 通用 → 登录项与扩展 中打开 Tern。"
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            fileProviderEnabled = false
            return "❌ 添加 File Provider 失败：\(message)"
        }
    }

    /// Probe the server through the same REST/session path used by File
    /// Provider.  No WebDAV mount or WebDAV request is involved.
    public func testConnection(serverURLText: String,
                               username: String,
                               password: String) async -> String {
        let url: URL
        do {
            url = try SettingsStore.normalize(serverText: serverURLText)
        } catch {
            return "❌ \(error.localizedDescription)"
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return "❌ 请填写用户名。" }
        var secret = password
        if secret.isEmpty {
            secret = storedPassword(for: url, username: trimmedUsername) ?? ""
        }
        guard !secret.isEmpty else { return "❌ 请填写密码。" }

        do {
            let client = try TernSyncClient(serverURL: url, username: trimmedUsername, password: secret)
            _ = try await client.watch(cursor: nil, timeout: 1)
            return "✅ 服务器可达，登录和同步接口正常。"
        } catch let error as SyncClientError {
            if case .http(401, _) = error {
                return "❌ 认证失败（HTTP 401）：用户名或密码不正确。"
            }
            return "❌ 无法连接：\(error.errorDescription ?? error.localizedDescription)"
        } catch {
            return "❌ 无法连接：\(error.localizedDescription)"
        }
    }

    public func refreshCredentialState() {
        guard let url = try? settings.validatedServerURL(), !settings.username.isEmpty else {
            credentialsReady = false
            cachedPassword = nil
            cachedCredentialKey = nil
            return
        }
        _ = storedPassword(for: url, username: settings.username)
    }

    public func clearCredentialCache() {
        cachedPassword = nil
        cachedCredentialKey = nil
        credentialsReady = false
    }

    // MARK: - Actions

    public func openInFinder() {
        FileProviderBridge.openInFinder()
    }

    public func copyServerAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serverURLText, forType: .string)
    }

    // MARK: - Clipboard

    public func sendClipboardToTern() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            presentClipboardError("剪贴板里没有可发送的文本。")
            return
        }
        Task {
            do {
                let client = try sharedClient()
                _ = try await client.putClipboard(text: text, device: clipboardDeviceName)
                await MainActor.run {
                    presentClipboardInfo("剪贴板已发送到 Tern", "远端设备可以通过「从 Tern 获取剪贴板」取得这段文本。")
                }
            } catch {
                await MainActor.run {
                    presentClipboardError("发送剪贴板失败：\(error.localizedDescription)")
                }
            }
        }
    }

    public func fetchClipboardFromTern() {
        Task {
            do {
                let client = try sharedClient()
                guard let clipboard = try await client.getClipboard() else {
                    await MainActor.run { presentClipboardError("Tern 上还没有保存的剪贴板内容。") }
                    return
                }
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(clipboard.text, forType: .string)
                    presentClipboardInfo("已获取 Tern 剪贴板",
                                         "已写入本地剪贴板\(clipboard.device.map { "（来自 \($0)）" } ?? "")。")
                }
            } catch {
                await MainActor.run {
                    presentClipboardError("获取剪贴板失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private var clipboardDeviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private func sharedClient() throws -> TernSyncClient {
        guard let config = FileProviderShared.loadConfiguration(),
              let password = FileProviderShared.loadPassword(serverURL: config.serverURL,
                                                             username: config.username) else {
            throw SyncClientError.notConfigured
        }
        return try TernSyncClient(serverURL: config.serverURL,
                                  username: config.username,
                                  password: password)
    }

    private func presentClipboardInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentClipboardError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Tern 剪贴板"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// Stop the long-poll watcher and prevent the File Provider extension from
    /// making network requests. Cached files remain available in Finder.
    public func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        FileProviderShared.setSyncEnabled(enabled)
        if enabled {
            if FileProviderShared.loadConfiguration() != nil {
                configureWatcher()
                fileProviderWatcher.start()
                FileProviderBridge.signalChanges()
            }
        } else {
            fileProviderWatcher.stop()
        }
        CDLog.info("app: sync enabled=\(enabled)")
    }

    public func toggleSync() {
        setSyncEnabled(!syncEnabled)
    }

    public func openLog() {
        let url = CDLog.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    public func openSettings() {
        SettingsWindowHelper.openSettings()
    }

    public func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Keychain cache

    private func storedPassword(for url: URL, username: String) -> String? {
        let key = KeychainStore.account(serverURL: url, username: username)
        if key == cachedCredentialKey {
            return cachedPassword
        }
        let value = KeychainStore.loadPassword(serverURL: url, username: username)
        cachedCredentialKey = key
        cachedPassword = value
        credentialsReady = value != nil
        return value
    }
}

// MARK: - Settings window

@MainActor
enum SettingsWindowHelper {

    static func openSettings() {
        CDLog.info("settings: opening settings window")
        SettingsWindowController.shared.show()
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Tern 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        let root = SettingsView(model: AppModel.shared, settings: SettingsStore.shared)
            .frame(minWidth: 560, minHeight: 560)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 600, height: 600))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        CDLog.info("settings: window visible=\(window?.isVisible ?? false)")
    }
}
