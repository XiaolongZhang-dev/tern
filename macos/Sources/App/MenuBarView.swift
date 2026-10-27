//
//  MenuBarView.swift
//  Tern (Tern) macOS menu-bar client
//
//  The dropdown attached to the menu-bar icon.
//

import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text("最近同步时间：\(model.lastSyncText)")
            .font(.caption)

        Divider()

        if FileProviderShared.loadConfiguration() != nil {
            Button(model.syncEnabled ? "断开同步" : "启用同步") {
                model.toggleSync()
            }
            Button("打开 Tern") {
                model.openInFinder()
            }
        } else {
            Button("配置 Tern…") {
                model.openSettings()
            }
        }
        Button("设置…") {
            model.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()
        Button("发送剪贴板到 Tern") {
            model.sendClipboardToTern()
        }
        Button("从 Tern 获取剪贴板") {
            model.fetchClipboardFromTern()
        }

        Divider()
        Button("复制服务器地址") {
            model.copyServerAddress()
        }
        Button("打开日志") {
            model.openLog()
        }

        Divider()

        Button("退出 Tern") {
            model.quit()
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
