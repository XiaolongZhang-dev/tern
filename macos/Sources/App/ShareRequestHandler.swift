//
//  ShareRequestHandler.swift
//  The File Provider action cannot show UI, so it stores a share request in the
//  shared Keychain and posts a Darwin notification. The menu-bar app owns the
//  policy dialog, API call and pasteboard write.
//

import AppKit
import Foundation
import FileProvider

private let shareRequestCallback: CFNotificationCallback = { _, _, _, _, _ in
    DispatchQueue.main.async {
        ShareRequestHandler.shared.processPending()
    }
}

@MainActor
final class ShareRequestHandler {
    static let shared = ShareRequestHandler()

    private var observing = false
    private var presenting = false

    private init() {}

    func start() {
        guard !observing else { return }
        observing = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            shareRequestCallback,
            FileProviderShared.shareRequestNotification as CFString,
            nil,
            .deliverImmediately
        )
        // No periodic Keychain poll: a pending share request now arrives via
        // the tern:// URL scheme instead of a shared Keychain item.
    }

    func stop() {
        guard observing else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(FileProviderShared.shareRequestNotification as CFString),
            nil
        )
        observing = false
    }

    func processPending() {
        guard !presenting else { return }
        if let action = FileProviderShared.takeFinderAction() {
            presenting = true
            handleFinderAction(action)
            return
        }
        guard let request = FileProviderShared.takeShareRequest() else { return }
        presenting = true
        defer { presenting = false }

        NSApp.activate(ignoringOtherApps: true)
        showSharePolicy(nodeId: request.nodeId, name: request.name)
    }

    func handleShareURL(_ url: URL) {
        guard url.scheme == "tern", url.host == "share",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let nodeId = components.queryItems?.first(where: { $0.name == "nodeId" })?.value,
              !nodeId.isEmpty else { return }
        let name = components.queryItems?.first(where: { $0.name == "name" })?.value ?? "Tern 文件"
        guard !presenting else { return }
        presenting = true
        defer { presenting = false }
        NSApp.activate(ignoringOtherApps: true)
        showSharePolicy(nodeId: nodeId, name: name)
    }

    private func showSharePolicy(nodeId: String, name: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "分享「\(name)」"
        alert.informativeText = "选择这条分享链接的有效期和密码。默认 24 小时、无密码。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "创建并复制链接")
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
        let passwordLabel = NSTextField(labelWithString: "分享密码（可选）")
        passwordLabel.frame = NSRect(x: 0, y: 66, width: 150, height: 20)
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 38, width: 350, height: 25))
        passwordField.placeholderString = "留空则不需要密码"
        let expiryLabel = NSTextField(labelWithString: "有效期")
        expiryLabel.frame = NSRect(x: 0, y: 12, width: 70, height: 20)
        let expiryPopup = NSPopUpButton(frame: NSRect(x: 76, y: 6, width: 160, height: 26), pullsDown: false)
        let policies: [(String, Int?)] = [
            ("24 小时（默认）", 24),
            ("1 小时", 1),
            ("7 天", 24 * 7),
            ("30 天", 24 * 30),
            ("永久", nil),
        ]
        for (title, hours) in policies {
            expiryPopup.addItem(withTitle: title)
            expiryPopup.lastItem?.representedObject = hours
        }
        expiryPopup.selectItem(at: 0)
        accessory.addSubview(passwordLabel)
        accessory.addSubview(passwordField)
        accessory.addSubview(expiryLabel)
        accessory.addSubview(expiryPopup)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = passwordField.stringValue
        let hours = expiryPopup.selectedItem?.representedObject as? Int
        createShare(nodeId: nodeId, name: name,
                    password: password.isEmpty ? nil : password,
                    expiresInHours: hours)
    }

    private func handleFinderAction(_ action: FileProviderShared.FinderAction) {
        Task {
            defer { Task { @MainActor in self.presenting = false } }
            do {
                let nodes = try await resolveNodes(paths: action.paths)
                switch action.kind {
                case "share":
                    guard let first = nodes.first else { throw FinderActionError.notFound }
                    await MainActor.run {
                        NSApp.activate(ignoringOtherApps: true)
                        self.showSharePolicy(nodeId: first.id, name: first.name ?? "Tern 文件")
                    }
                case "keep", "remove":
                    let manager = NSFileProviderManager(for: FileProviderBridge.domain)
                    for node in nodes {
                        FileProviderShared.setPinned(action.kind == "keep", itemIdentifier: node.id)
                        if action.kind == "remove" {
                            manager?.evictItem(identifier: NSFileProviderItemIdentifier(node.id)) { _ in }
                        }
                    }
                    FileProviderBridge.signalChanges()
                default:
                    break
                }
            } catch {
                await MainActor.run {
                    self.presentError("操作失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func resolveNodes(paths: [String]) async throws -> [TernChange] {
        guard let config = FileProviderShared.loadConfiguration(),
              let password = FileProviderShared.loadPassword(serverURL: config.serverURL,
                                                             username: config.username) else {
            throw SyncClientError.notConfigured
        }
        let root = try cloudStorageRoot()
        let wanted = paths.compactMap { path -> String? in
            let target = URL(fileURLWithPath: path).standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            guard target.hasPrefix(rootPath + "/") else { return nil }
            return String(target.dropFirst(rootPath.count + 1))
        }
        guard !wanted.isEmpty else { throw FinderActionError.outsideRoot }

        let client = try TernSyncClient(serverURL: config.serverURL,
                                        username: config.username,
                                        password: password)
        let page = try await client.sync(cursor: 0)
        var byId: [String: TernChange] = [:]
        for change in page.changes where !change.deleted {
            byId[change.id] = change
        }
        var pathsById: [String: String] = [:]
        func pathFor(_ node: TernChange, _ guardSet: inout Set<String>) -> String? {
            if let cached = pathsById[node.id] { return cached }
            guard guardSet.insert(node.id).inserted else { return nil }
            var value = node.name ?? ""
            if let parentId = node.parentId, let parent = byId[parentId],
               let parentPath = pathFor(parent, &guardSet) {
                value = parentPath + "/" + value
            }
            pathsById[node.id] = value
            return value
        }
        var result: [TernChange] = []
        for target in wanted {
            var found: TernChange?
            for node in byId.values {
                var set = Set<String>()
                if let path = pathFor(node, &set),
                   path.caseInsensitiveCompare(target) == .orderedSame {
                    found = node
                    break
                }
            }
            if let found { result.append(found) }
        }
        if result.isEmpty { throw FinderActionError.notFound }
        return result
    }

    private func cloudStorageRoot() throws -> URL {
        let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: cloudStorage,
                                                                    includingPropertiesForKeys: nil)) ?? []
        if let match = entries.first(where: { $0.lastPathComponent.hasPrefix("Tern") }) {
            return match
        }
        throw FinderActionError.notFound
    }

    private enum FinderActionError: LocalizedError {
        case outsideRoot
        case notFound
        var errorDescription: String? {
            switch self {
            case .outsideRoot: return "只能操作 Tern 同步文件夹中的项目。"
            case .notFound: return "没有找到对应的 Tern 文件，请稍后再试。"
            }
        }
    }

    private func createShare(nodeId: String, name: String, password: String?, expiresInHours: Int?) {
        Task {
            do {
                let client = try sharedClient()
                let share = try await client.createShare(nodeId: nodeId, password: password, expiresInHours: expiresInHours)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(share.url, forType: .string)
                await MainActor.run {
                    presentResult(title: "分享链接已复制",
                                  message: name,
                                  url: share.url,
                                  hasPassword: share.hasPassword)
                }
            } catch {
                await MainActor.run {
                    presentError("创建分享链接失败：\(error.localizedDescription)")
                }
            }
        }
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

    private func presentResult(title: String, message: String, url: String, hasPassword: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(message)\n\(url)\n\n\(hasPassword ? "已设置分享密码" : "无密码公开链接")"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Tern 分享失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
