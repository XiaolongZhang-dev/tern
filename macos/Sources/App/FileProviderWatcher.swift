//
//  FileProviderWatcher.swift
//  Keeps a long-poll request open against /api/sync/watch while Tern is
//  running, and wakes File Provider whenever another client changes the tree.
//
//  The extension cannot be relied on to stay alive, so the menu-bar app owns
//  the connection. It uses the same shared-Keychain credentials as File
//  Provider and does not touch WebDAV.
//

import Foundation

@available(macOS 13.0, *)
public final class FileProviderWatcher: @unchecked Sendable {

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    /// Called after every successful long-poll return, including a timeout
    /// with no changes. That is the "last successful check" timestamp.
    public var onCheck: (@Sendable () -> Void)?

    public init() {}

    public func start() {
        stop()
        lock.lock()
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run()
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let current = task
        task = nil
        lock.unlock()
        current?.cancel()
    }

    deinit {
        task?.cancel()
    }

    private func run() async {
        var cursor: Int?
        var client: TernSyncClient?
        while !Task.isCancelled {
            guard let configuration = FileProviderShared.loadConfiguration(),
                  let password = FileProviderShared.loadPassword(
                    serverURL: configuration.serverURL,
                    username: configuration.username
                  ) else {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }

            do {
                if client == nil {
                    client = try TernSyncClient(
                        serverURL: configuration.serverURL,
                        username: configuration.username,
                        password: password
                    )
                }
                guard let client else { continue }
                if let current = cursor {
                    let page = try await client.watch(cursor: current, timeout: 25)
                    onCheck?()
                    if page.changed {
                        cursor = page.cursor
                        signalFileProvider()
                    }
                } else {
                    let head = try await client.watch(cursor: nil, timeout: 25)
                    cursor = head.cursor
                    onCheck?()
                    signalFileProvider()
                }
            } catch {
                if Task.isCancelled { return }
                client = nil
                CDLog.warn("fileprovider watcher: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func signalFileProvider() {
        CDLog.info("fileprovider watcher: change detected")
        Task { @MainActor in
            FileProviderBridge.signalChanges()
        }
    }
}
