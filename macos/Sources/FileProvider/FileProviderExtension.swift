//
//  FileProviderExtension.swift
//  Replicated File Provider with on-demand download, writes, offline queue,
//  conflict copies, thumbnails and custom "keep downloaded" actions.
//

import Foundation
import AppKit
import FileProvider
import UniformTypeIdentifiers
import Network

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {

    let domain: NSFileProviderDomain
    let store = FileProviderStore()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.tern.menubar.fileprovider.network")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            if online {
                Task {
                    try? await self.store.flushPending()
                    self.signalChanges()
                }
            } else {
                FileProviderShared.updateSyncStatus(
                    pending: self.store.pending.list().count,
                    error: "网络不可用，等待恢复后自动重连"
                )
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func invalidate() {
        pathMonitor.cancel()
    }

    // MARK: - Metadata

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        if identifier == .rootContainer {
            progress.completedUnitCount = 1
            completionHandler(TernRootItem(), nil)
            return progress
        }

        if let stored = store.item(id: identifier.rawValue) {
            progress.completedUnitCount = 1
            completionHandler(TernItem(stored: stored), nil)
            return progress
        }

        Task {
            do {
                if store.cursor == 0 { _ = try await store.sync(forceBootstrap: true) }
                if let stored = store.item(id: identifier.rawValue) {
                    progress.completedUnitCount = 1
                    completionHandler(TernItem(stored: stored), nil)
                } else {
                    completionHandler(nil, Self.noSuchItem())
                }
            } catch {
                completionHandler(nil, Self.providerError(error))
            }
        }
        return progress
    }

    // MARK: - Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        Task {
            do {
                guard let stored = store.item(id: itemIdentifier.rawValue), !stored.isFolder else {
                    completionHandler(nil, nil, Self.noSuchItem())
                    return
                }
                let data: Data
                if let pendingURL = store.pendingContentURL(nodeId: stored.id) {
                    data = try Data(contentsOf: pendingURL)
                } else {
                    let client = try store.makeClient()
                    data = try await client.fetchFile(id: stored.id).data
                }
                let manager = NSFileProviderManager(for: domain)
                let directory = (manager.flatMap { try? $0.temporaryDirectoryURL() })
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("TernFileProvider", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileURL = directory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension((stored.name as NSString).pathExtension.isEmpty ? "data" : (stored.name as NSString).pathExtension)
                try data.write(to: fileURL, options: .atomic)
                progress.completedUnitCount = 100
                completionHandler(fileURL, TernItem(stored: stored), nil)
            } catch {
                completionHandler(nil, nil, Self.providerError(error))
            }
        }
        return progress
    }

    // MARK: - Writes

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        let parent = itemTemplate.parentItemIdentifier == .rootContainer ? nil : itemTemplate.parentItemIdentifier.rawValue
        let name = itemTemplate.filename
        let isFolder = itemTemplate.contentType == .folder
        let clientId = UUID().uuidString.lowercased()

        Task {
            do {
                let client = try store.makeClient()
                let change: TernChange
                if isFolder {
                    change = try await client.createFolder(parentId: parent, name: name, clientId: clientId)
                } else {
                    guard let url, let data = try? Data(contentsOf: url) else {
                        completionHandler(nil, [], false, Self.unsupported())
                        return
                    }
                    let mime = itemTemplate.contentType?.preferredMIMEType ?? "application/octet-stream"
                    if data.count >= 32 * 1024 * 1024 {
                        change = try await client.uploadFileResumable(parentId: parent, name: name, data: data, mime: mime)
                    } else {
                        change = try await client.uploadFile(parentId: parent, name: name, clientId: clientId, data: data, mime: mime)
                    }
                }
                guard let stored = store.upsert(change) else {
                    throw SyncClientError.malformedResponse
                }
                progress.completedUnitCount = 100
                signalChanges()
                completionHandler(TernItem(stored: stored), [], false, nil)
            } catch {
                guard Self.isOffline(error) else {
                    completionHandler(nil, [], false, Self.providerError(error))
                    return
                }
                let localId = UUID().uuidString.lowercased()
                let now = ISO8601DateFormatter().string(from: Date())
                var contentFile: String? = nil
                if !isFolder, let url {
                    if let data = try? Data(contentsOf: url) {
                        contentFile = store.pending.writeContent(data)
                    }
                }
                let kind: PendingKind = isFolder ? .createFolder : .createFile
                store.pending.add(PendingOperation(
                    id: UUID().uuidString,
                    kind: kind,
                    clientId: localId,
                    nodeId: localId,
                    parentId: parent,
                    name: name,
                    moveToRoot: false,
                    contentFile: contentFile,
                    baseEtag: nil,
                    createdAt: Date().timeIntervalSince1970
                ))
                let local = StoredItem(
                    id: localId,
                    parentId: parent,
                    name: name,
                    type: isFolder ? "folder" : "file",
                    size: 0,
                    mime: itemTemplate.contentType?.preferredMIMEType,
                    createdAt: now,
                    updatedAt: now,
                    etag: nil,
                    deleted: false,
                    pending: true
                )
                store.upsertLocal(local)
                completionHandler(TernItem(stored: local), [], false, nil)
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        Task {
            do {
                guard let stored = store.item(id: item.itemIdentifier.rawValue) else {
                    completionHandler(nil, [], false, Self.noSuchItem())
                    return
                }
                let client = try store.makeClient()
                var latest = stored
                let baseEtag = changedFields.contains(.contents)
                    ? String(data: version.contentVersion, encoding: .utf8)
                    : nil

                if changedFields.contains(.contents), let newContents {
                    let data = try Data(contentsOf: newContents)
                    let updated = try await client.updateContent(id: stored.id, data: data, ifMatch: baseEtag)
                    if let storedUpdated = store.upsert(updated) { latest = storedUpdated }
                }
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newName = changedFields.contains(.filename) ? item.filename : nil
                    var newParent: String? = nil
                    var moveToRoot = false
                    if changedFields.contains(.parentItemIdentifier) {
                        if item.parentItemIdentifier == .rootContainer {
                            moveToRoot = true
                        } else {
                            newParent = item.parentItemIdentifier.rawValue
                        }
                    }
                    let updated = try await client.renameMove(
                        id: stored.id,
                        name: newName,
                        parentId: newParent,
                        moveToRoot: moveToRoot,
                        ifMatch: nil
                    )
                    if let storedUpdated = store.upsert(updated) { latest = storedUpdated }
                }
                progress.completedUnitCount = 100
                signalChanges()
                completionHandler(TernItem(stored: latest), [], false, nil)
            } catch {
                if case SyncClientError.http(412, _) = error,
                   let newContents,
                   let stored = store.item(id: item.itemIdentifier.rawValue),
                   let data = try? Data(contentsOf: newContents) {
                    await makeConflictCopy(stored: stored, data: data, originalName: item.filename)
                    completionHandler(nil, [], false, Self.conflictError())
                    return
                }
                guard Self.isOffline(error) else {
                    completionHandler(nil, [], false, Self.providerError(error))
                    return
                }
                guard let stored = store.item(id: item.itemIdentifier.rawValue) else {
                    completionHandler(nil, [], false, Self.noSuchItem())
                    return
                }
                var local = stored
                local.pending = true
                local.updatedAt = ISO8601DateFormatter().string(from: Date())
                if changedFields.contains(.filename) { local.name = item.filename }
                if changedFields.contains(.parentItemIdentifier) {
                    local.parentId = item.parentItemIdentifier == .rootContainer ? nil : item.parentItemIdentifier.rawValue
                }
                if changedFields.contains(.contents), let newContents, let data = try? Data(contentsOf: newContents),
                   let contentFile = store.pending.writeContent(data) {
                    store.pending.add(PendingOperation(
                        id: UUID().uuidString,
                        kind: .modifyContent,
                        clientId: nil,
                        nodeId: stored.id,
                        parentId: nil,
                        name: nil,
                        moveToRoot: false,
                        contentFile: contentFile,
                        baseEtag: stored.etag,
                        createdAt: Date().timeIntervalSince1970
                    ))
                    local.size = Int64(data.count)
                }
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let root = item.parentItemIdentifier == .rootContainer
                    store.pending.add(PendingOperation(
                        id: UUID().uuidString,
                        kind: .renameMove,
                        clientId: nil,
                        nodeId: stored.id,
                        parentId: root ? nil : item.parentItemIdentifier.rawValue,
                        name: changedFields.contains(.filename) ? item.filename : nil,
                        moveToRoot: root && changedFields.contains(.parentItemIdentifier),
                        contentFile: nil,
                        baseEtag: nil,
                        createdAt: Date().timeIntervalSince1970
                    ))
                }
                store.upsertLocal(local)
                completionHandler(TernItem(stored: local), [], false, nil)
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        Task {
            do {
                let client = try store.makeClient()
                try await client.delete(id: identifier.rawValue)
                store.remove(id: identifier.rawValue)
                progress.completedUnitCount = 100
                signalChanges()
                completionHandler(nil)
            } catch {
                guard Self.isOffline(error) else {
                    completionHandler(Self.providerError(error))
                    return
                }
                store.remove(id: identifier.rawValue)
                store.pending.add(PendingOperation(
                    id: UUID().uuidString,
                    kind: .delete,
                    clientId: nil,
                    nodeId: identifier.rawValue,
                    parentId: nil,
                    name: nil,
                    moveToRoot: false,
                    contentFile: nil,
                    baseEtag: nil,
                    createdAt: Date().timeIntervalSince1970
                ))
                completionHandler(nil)
            }
        }
        return progress
    }

    private func change(from stored: StoredItem) -> StoredItem { stored }

    private static func isOffline(_ error: Error) -> Bool {
        if case .syncPaused = error as? SyncClientError { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer {
            throw Self.unsupported()
        }
        if containerItemIdentifier == .rootContainer || containerItemIdentifier == .workingSet {
            return TernEnumerator(container: containerItemIdentifier, store: store)
        }
        guard store.item(id: containerItemIdentifier.rawValue) != nil else {
            throw Self.noSuchItem()
        }
        return TernEnumerator(container: containerItemIdentifier, store: store)
    }

    private func makeConflictCopy(stored: StoredItem, data: Data, originalName: String) async {
        do {
            let client = try store.makeClient()
            let ns = originalName as NSString
            let ext = ns.pathExtension
            let base = ns.deletingPathExtension
            let name = ext.isEmpty ? "\(base) (conflicted copy)" : "\(base) (conflicted copy).\(ext)"
            let change = try await client.uploadFile(
                parentId: stored.parentId,
                name: name,
                clientId: UUID().uuidString.lowercased(),
                data: data,
                mime: stored.mime ?? "application/octet-stream"
            )
            _ = store.upsert(change)
            FileProviderShared.updateSyncStatus(pending: 0, error: "已生成冲突副本：\(name)")
            signalChanges()
        } catch {
            FileProviderShared.updateSyncStatus(pending: 1, error: "冲突副本创建失败：\(error.localizedDescription)")
        }
    }

    private func signalChanges() {
        let manager = NSFileProviderManager(for: domain)
        manager?.signalEnumerator(for: .workingSet) { _ in }
        manager?.signalEnumerator(for: .rootContainer) { _ in }
    }

    // MARK: - Errors

    private static func providerError(_ error: Error) -> NSError {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return NSError(domain: NSFileProviderErrorDomain, code: -1004, userInfo: [
            NSLocalizedDescriptionKey: description,
        ])
    }

    private static func noSuchItem() -> NSError {
        NSError(domain: NSFileProviderErrorDomain, code: -1005, userInfo: [
            NSLocalizedDescriptionKey: "Tern 中不存在该文件。",
        ])
    }

    private static func conflictError() -> NSError {
        NSError(domain: NSFileProviderErrorDomain, code: -2005, userInfo: [
            NSLocalizedDescriptionKey: "服务器上的文件已被修改，本地内容已保存为冲突副本。",
        ])
    }

    // MARK: - Custom actions

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: Int64(itemIdentifiers.count))
        Task {
            switch actionIdentifier.rawValue {
            case "com.tern.fileprovider.keepDownloaded":
                for identifier in itemIdentifiers {
                    FileProviderShared.setPinned(true, itemIdentifier: identifier.rawValue)
                }
                signalChanges()
                completionHandler(nil)
            case "com.tern.fileprovider.removeDownload":
                let manager = NSFileProviderManager(for: domain)
                for identifier in itemIdentifiers {
                    FileProviderShared.setPinned(false, itemIdentifier: identifier.rawValue)
                    manager?.evictItem(identifier: identifier) { _ in }
                }
                signalChanges()
                completionHandler(nil)
            case "com.tern.fileprovider.share":
                guard let identifier = itemIdentifiers.first else {
                    completionHandler(NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileNoSuchFileError,
                        userInfo: [NSLocalizedDescriptionKey: "请选择一个要分享的项目"]
                    ))
                    return
                }
                let name = store.item(id: identifier.rawValue)?.name ?? "Tern 文件"
                var components = URLComponents()
                components.scheme = "tern"
                components.host = "share"
                components.queryItems = [
                    URLQueryItem(name: "nodeId", value: identifier.rawValue),
                    URLQueryItem(name: "name", value: name),
                ]
                if let url = components.url {
                    NSWorkspace.shared.open(url)
                }
                completionHandler(nil)
            default:
                completionHandler(NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFeatureUnsupportedError,
                    userInfo: [NSLocalizedDescriptionKey: "不支持的 Tern 操作"]
                ))
            }
        }
        return progress
    }

    private static func unsupported() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
            NSLocalizedDescriptionKey: "Tern File Provider 目前是只读版本，写入功能将在下一阶段开放。",
        ])
    }
}
