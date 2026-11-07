//
//  TernApp.swift
//  Tern (Tern) macOS menu-bar client
//
//  SwiftUI `MenuBarExtra` app (macOS 13+) with an AppKit delegate for
//  lifecycle, a single-instance lock, and a set of hidden command-line modes
//  that make the app testable without a human clicking the menu bar.
//

import SwiftUI
import AppKit
import Darwin

// MARK: - Entry point

@main
struct TernMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        // Hidden non-GUI modes: --set-password, --login-item, --file-provider-*, ...
        if let first = arguments.first, first.hasPrefix("--") {
            if let exitCode = CommandLineModes.run(arguments: arguments) {
                exit(exitCode)
            }
        }

        guard SingleInstance.acquire() else {
            FileHandle.standardError.write(Data("Tern 已经在运行，本次启动已跳过。\n".utf8))
            exit(0)
        }
        TernApp.main()
    }
}

// MARK: - SwiftUI app

struct TernApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: AppModel.shared)
        } label: {
            MenuBarLabel(model: AppModel.shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .accessibilityLabel(Text("Tern"))
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already makes this an accessory app; keep
        // it that way even if someone launches the binary directly.
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "tern", url.host == "share" {
                ShareRequestHandler.shared.handleShareURL(url)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.openSettings()
        return true
    }
}

// MARK: - Single instance

enum SingleInstance {
    private static var lockFileDescriptor: Int32 = -1

    /// Ensure only one copy of the menu-bar app is running.  Returns `false`
    /// when another instance holds the lock.
    static func acquire() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tern", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent("app.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            // Cannot create a lock file (unusual); better to run than not.
            return true
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        lockFileDescriptor = descriptor
        return true
    }
}

// MARK: - Hidden command-line modes

/// The app binary doubles as a maintenance tool.  These modes run before
/// SwiftUI starts and never show any UI, which is what makes it possible to
/// test the menu-bar app from a terminal, CI job or automation script.
enum CommandLineModes {

    /// Returns an exit code when the arguments describe a headless mode, or
    /// `nil` when the app should start normally.
    static func run(arguments: [String]) -> Int32? {
        guard let command = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "--version":
            print(TernInfo.versionDescription)
            return 0
        case "--help":
            print(helpText())
            return 0

        case "--set-password":
            return runSetPassword(arguments: rest)
        case "--delete-password":
            return runDeletePassword(arguments: rest)
        case "--login-item":
            return runLoginItem(arguments: rest)
        case "--diagnose":
            return runDiagnose(arguments: rest)
        case "--file-provider-setup":
            return runFileProviderSetup(arguments: rest)
        case "--file-provider-remove":
            return runFileProviderRemove()
        case "--file-provider-cleanup":
            return runFileProviderCleanup()

        default:
            return nil
        }
    }

    private static func helpText() -> String {
        """
        \(TernInfo.versionDescription)

        菜单栏应用（直接打开即可）：
          open Tern.app

        隐藏的命令行模式（用于自动化与排障）：
          --set-password --url URL --user NAME --password PASS [--result FILE]
                                       把密码写入 macOS 钥匙串（以当前应用身份）
          --delete-password --url URL --user NAME
                                       删除钥匙串中的密码
          --login-item status|enable|disable [--result FILE]
                                       查看/启用/关闭登录启动（LaunchAgent）
          --file-provider-setup         把当前设置写入共享 Keychain 并注册 File Provider
          --file-provider-remove        移除 Tern File Provider domain
          --file-provider-cleanup       移除新旧 Tern File Provider domain 并清理数据
          --diagnose [--result FILE]   输出诊断信息
          --version                    显示版本
          --help                       显示本帮助
        """
    }

    // MARK: Mode implementations

    private static func parseFlags(_ arguments: [String]) -> [String: String] {
        var flags: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                flags[key] = arguments[index + 1]
                index += 2
            } else {
                flags[key] = ""
                index += 1
            }
        }
        return flags
    }

    private static func writeResult(_ text: String, to resultFile: String?) {
        print(text)
        fflush(stdout)
        if let resultFile = resultFile {
            try? text.write(toFile: resultFile, atomically: true, encoding: .utf8)
        }
    }

    private static func passwordFromFlags(_ flags: [String: String]) -> String {
        if let password = flags["--password"], !password.isEmpty { return password }
        if let environment = ProcessInfo.processInfo.environment["TERN_PASSWORD"] {
            return environment
        }
        return ""
    }

    private static func runSetPassword(arguments: [String]) -> Int32 {
        let flags = parseFlags(arguments)
        let resultFile = flags["--result"]
        guard let urlText = flags["--url"],
              let url = try? SettingsStore.normalize(serverText: urlText) else {
            writeResult("错误：请提供有效的 --url（例如 http://127.0.0.1:18080/Tern）", to: resultFile)
            return 1
        }
        guard let username = flags["--user"], !username.isEmpty else {
            writeResult("错误：请提供 --user", to: resultFile)
            return 1
        }
        let password = passwordFromFlags(flags)
        guard !password.isEmpty else {
            writeResult("错误：请提供 --password 或设置 TERN_PASSWORD 环境变量", to: resultFile)
            return 1
        }
        do {
            guard FileProviderShared.savePassword(password, serverURL: url, username: username) else {
                writeResult("错误：无法写入共享配置。", to: resultFile)
                return 1
            }
            writeResult("OK: 密码已保存到共享配置（\(username)@\(url.host ?? "?")）", to: resultFile)
            return 0
        } catch {
            writeResult("错误：\(error.localizedDescription)", to: resultFile)
            return 1
        }
    }

    private static func runDeletePassword(arguments: [String]) -> Int32 {
        let flags = parseFlags(arguments)
        let resultFile = flags["--result"]
        guard let urlText = flags["--url"],
              let url = try? SettingsStore.normalize(serverText: urlText),
              let username = flags["--user"], !username.isEmpty else {
            writeResult("错误：需要 --url 与 --user", to: resultFile)
            return 1
        }
        let deleted = FileProviderShared.deletePassword(serverURL: url, username: username)
        writeResult(deleted ? "OK: 已删除钥匙串密码" : "钥匙串中没有对应密码", to: resultFile)
        return 0
    }

    private static func runLoginItem(arguments: [String]) -> Int32 {
        let flags = parseFlags(arguments)
        let resultFile = flags["--result"]
        let action = arguments.first(where: { !$0.hasPrefix("--") }) ?? "status"
        switch action {
        case "status":
            writeResult("登录启动：\(LaunchAgentManager.statusDescription())\nplist: \(LaunchAgentManager.plistURL.path)", to: resultFile)
            return LaunchAgentManager.isInstalled() ? 0 : 3
        case "enable":
            do {
                try LaunchAgentManager.install(appURL: Bundle.main.bundleURL)
                writeResult("OK: 已启用登录启动\nplist: \(LaunchAgentManager.plistURL.path)\n\(LaunchAgentManager.statusDescription())", to: resultFile)
                return 0
            } catch {
                writeResult("错误：\(error.localizedDescription)", to: resultFile)
                return 1
            }
        case "disable":
            LaunchAgentManager.uninstall()
            writeResult("OK: 已关闭登录启动，plist 已删除", to: resultFile)
            return 0
        default:
            writeResult("错误：--login-item 只支持 status|enable|disable", to: resultFile)
            return 1
        }
    }

    private static func runDiagnose(arguments: [String]) -> Int32 {
        let flags = parseFlags(arguments)
        let resultFile = flags["--result"]
        let settings = SettingsStore.shared
        var lines: [String] = []
        lines.append(TernInfo.versionDescription)
        lines.append("bundle: \(Bundle.main.bundleURL.path)")
        lines.append("executable: \(Bundle.main.executableURL?.path ?? "?")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(x86_64)
        lines.append("arch: x86_64 (compiled)")
        #elseif arch(arm64)
        lines.append("arch: arm64 (compiled)")
        #else
        lines.append("arch: unknown (compiled)")
        #endif
        let serverURL = (try? settings.validatedServerURL())?.absoluteString ?? settings.serverURLText
        lines.append("server: \(serverURL)")
        lines.append("user: \(settings.username.isEmpty ? "(未设置)" : settings.username)")
        lines.append("connectAtLogin(defaults): \(settings.connectAtLogin)")
        lines.append("launchAgent: \(LaunchAgentManager.statusDescription())")
        if let url = try? settings.validatedServerURL(), !settings.username.isEmpty {
            let password = FileProviderShared.loadPassword(serverURL: url, username: settings.username)
            lines.append("keychainPassword: \(password == nil ? "未保存" : "已保存")")
        }
        if let configuration = FileProviderShared.loadConfiguration() {
            lines.append("fileProviderConfigured: yes")
            lines.append("fileProviderServer: \(configuration.serverURL.absoluteString)")
        } else {
            lines.append("fileProviderConfigured: no")
        }
        let sync = FileProviderShared.syncStatus()
        lines.append("fileProviderPending: \(sync.pending)")
        lines.append("fileProviderLastError: \(sync.error ?? "无")")
        lines.append("log: \(CDLog.fileURL.path)")
        writeResult(lines.joined(separator: "\n"), to: resultFile)
        return 0
    }
}


// MARK: - File Provider maintenance modes

extension CommandLineModes {
    fileprivate static func runFileProviderSetup(arguments: [String]) -> Int32 {
        let flags = parseFlags(arguments)
        Task {
            do {
                let store = SettingsStore.shared
                let url = try store.validate()
                let username = store.username.trimmingCharacters(in: .whitespacesAndNewlines)
                let password = flags["--password"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? FileProviderShared.loadPassword(serverURL: url, username: username)
                    ?? ProcessInfo.processInfo.environment["TERN_PASSWORD"]
                guard let password, !password.isEmpty else {
                    FileHandle.standardError.write(Data("错误：钥匙串中没有密码，请在 Tern 设置里重新填写并保存。\n".utf8))
                    exit(1)
                }
                FileProviderShared.saveConfiguration(serverURL: url, username: username)
                guard FileProviderShared.savePassword(password, serverURL: url, username: username) else {
                    FileHandle.standardError.write(Data("错误：无法写入共享配置（扩展容器不可写）。\n".utf8))
                    exit(1)
                }
                try await FileProviderBridge.addDomain()
                print("OK: File Provider domain registered")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(("错误：" + error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        return 1
    }


}

extension CommandLineModes {
    fileprivate static func runFileProviderRemove() -> Int32 {
        Task {
            do {
                try await FileProviderBridge.removeDomain()
                print("OK: File Provider domain removed")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(("错误：" + error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        return 1
    }
}

extension CommandLineModes {
    fileprivate static func runFileProviderCleanup() -> Int32 {
        Task {
            for identifier in [
                "com.tern.menubar.fileprovider",
                "com.tern.menubar.fileprovider.offline",
                "com.tern.menubar.fileprovider.offline3",
            ] {
                do {
                    try await FileProviderBridge.removeDomain(identifier: identifier)
                    print("removed: \(identifier)")
                } catch {
                    print("skip/err: \(identifier): \(error.localizedDescription)")
                }
            }
            exit(0)
        }
        RunLoop.main.run()
        return 1
    }
}
