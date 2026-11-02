# macOS 客户端（File Provider）

Tern for macOS 是菜单栏应用 + File Provider 扩展。它**不再挂载 WebDAV**，也不使用
`/Volumes` 网络卷；Finder 中的 Tern 是原生 File Provider 位置，和 iCloud Drive
并列显示，支持按需下载、在线/离线写入、冲突副本和实时同步。

> 当前版本：**1.2.1**。Personal Team 签名可用；正式分发仍需 Developer ID +
> notarization。

## 架构

```text
Tern.app（菜单栏，常驻）
  ├── FileProviderWatcher
  │     └── 长轮询 GET /api/sync/watch
  │           └── 有变化时 signalEnumerator
  └── TernFileProvider.appex
        ├── FileProviderExtension（NSFileProviderReplicatedExtension）
        ├── TernEnumerator
        └── FileProviderStore（扩展容器内缓存）
              │
              ▼
        https://host:port/api/...
```

- File Provider 扩展走 REST：
  `GET /api/sync/changes`、`GET/PUT /api/nodes/:id/content`、
  `POST /api/auth/login` 等；
- 菜单栏 App 的 watcher 保持一条 `/api/sync/watch` 长轮询；网页/WebDAV/
  其他 Mac 的改动会在大约 1 秒内 signal 到 File Provider；
- 连接信息、密码、同步状态、保持下载标记放在共享 Keychain；
- 扩展缓存和离线队列放在扩展自己的容器，不依赖 App Group；
- **Mac 客户端不调用 WebDAV**。服务端仍保留 WebDAV 端点给 Windows/rclone 等
  客户端使用。

## 构建

需要完整 Xcode（不是只有 Command Line Tools）：

```bash
cd macos
TEAM=你的TeamID ./build-xcode.sh
```

`build-xcode.sh` 会：

1. 用 XcodeGen 生成 `Tern.xcodeproj`；
2. 编译菜单栏 App 和 `TernFileProvider.appex`；
3. 用自动签名/Personal Team 生成 provisioning profile；
4. 输出 `.build-xcode/Build/Products/Debug/Tern.app`。

没有 `TEAM` 时仍可编译用于 CI，但没有签名，File Provider 扩展无法注册。

### 本机运行：ad-hoc 签名（不需要 Apple 账号）

只想在这台 Mac 上用，不需要分发时，用 ad-hoc 签名即可。它没有 provisioning
profile，因此**永不过期**：

```bash
cd macos
ADHOC=1 ./build-xcode.sh
ditto .build-xcode/Build/Products/Debug/Tern.app /Applications/Tern.app
open /Applications/Tern.app
```

之所以可行，是因为共享配置不再走 Keychain 群组。`keychain-access-groups` 是受限
entitlement，AMFI 只认由描述文件背书的签名，ad-hoc 二进制只要声明它就会被拒绝执行
（`The file is adhoc signed but contains restricted entitlements`）。现在 App 与
扩展改为交换扩展容器里的文件：

```text
~/Library/Containers/com.tern.menubar.FileProvider/Data/Library/Application Support/TernShared/
  com.tern.menubar.fileprovider.config--config--<hash>.bin        服务器地址 / 用户名
  com.tern.menubar.fileprovider--<user>@<host>:<port>--<hash>.bin 密码（0600）
  …status / pinned / sync / shareRequest
```

菜单栏 App 未沙盒化，直接写这个目录；扩展被沙盒化，把它当作自己的 home 读取。目录
权限 `0700`、文件 `0600`，但**密码是明文落盘**——这是用 ad-hoc 换取免账号、免过期
的代价；需要更强保护就用下面的 Team 签名（配置仍走同一套文件，Keychain 只在
App 自己存密码时使用）。

### 免费 Personal Team（需要账号，7 天过期）

- 不需要 App Groups，也不需要 Keychain Sharing——共享配置走上面的容器文件；
- `com.apple.developer.fileprovider.testing-mode` 不可用（Personal Team
  明确不支持），第一次添加 domain 后需要在系统设置里手动启用一次；
- 免费描述文件有效期只有 **7 天**，过期后 App 无法启动，需要重新
  `TEAM=你的TeamID ./build-xcode.sh`；
- 安装：

```bash
cp -R .build-xcode/Build/Products/Debug/Tern.app /Applications/
open /Applications/Tern.app
```

### 旧版 `build.sh`

`build.sh` 只用 Command Line Tools 构建菜单栏 App，不包含 File Provider 扩展；
适合 CI/无 Xcode 环境，但**不能**注册 Finder 位置。要完整体验请用
`build-xcode.sh`。

## 首次使用

1. 打开 `Tern.app`；
2. 菜单栏 Tern →「设置」；
3. 填写：
   - 服务器地址：`https://<host>:<port>/Tern`
   - 用户名/密码：Tern 网页登录账号；
4. 点「保存」，再点「在 Finder 中启用 Tern」；
5. 打开 **系统设置 → 通用 → 登录项与扩展**，向下滚动到
   **文件提供程序 / File Providers**，启用 **Tern**；
6. 打开 Finder →「位置」→ **Tern**。

首次弹出「Tern 想访问受 Tern 管理的文件」时点允许。

## Finder 能力

- 按需下载、Quick Look、缩略图；
- 新建文件/文件夹、修改、重命名、移动、删除；
- 离线写队列：网络恢复后自动上传；
- 冲突副本：服务端返回 412 时保存
  `name (conflicted copy).ext`，不覆盖远端；
- 右键「保持下载 / 移除下载」；
- 网页/其他客户端上传后，Finder 自动出现，无需手动刷新；
- 菜单栏可查看待上传数量和最近错误。

## 启用 / 断开同步

菜单栏 Tern 菜单：

- **断开同步**：停止长轮询，同时 File Provider 扩展也不再发起网络请求；
  已下载文件仍然可以在 Finder 中打开；
- **启用同步**：重新开始长轮询和 File Provider 同步。

典型场景：修改密码后先断开同步，等待服务端登录频控窗口过去，再修改密码并启用同步，避免客户端反复用旧密码触发 429。

## 实时 watcher

File Provider 本身没有长连接。菜单栏 App 持有：

```text
GET /api/sync/watch?cursor=...
```

服务端挂起最多 25 秒；有变化立即返回。App 收到变化后调用
`NSFileProviderManager.signalEnumerator`，扩展再增量拉取
`/api/sync/changes`。空闲时每个 Mac 只有一条挂起的 HTTP 请求。

watcher 需要菜单栏 App 常驻，因此建议保留「登录时自动启动 Tern」。关闭 App
后 Finder 仍可按需拉取，但网页端变化不会主动出现。

## 命令行模式

```bash
"/Applications/Tern.app/Contents/MacOS/Tern" --help
"/Applications/Tern.app/Contents/MacOS/Tern" --diagnose
"/Applications/Tern.app/Contents/MacOS/Tern" --set-password --url URL --user NAME --password PASS
"/Applications/Tern.app/Contents/MacOS/Tern" --login-item status
"/Applications/Tern.app/Contents/MacOS/Tern" --file-provider-setup
"/Applications/Tern.app/Contents/MacOS/Tern" --file-provider-remove
"/Applications/Tern.app/Contents/MacOS/Tern" --file-provider-cleanup
```

## 分享与剪贴板

### 分享文件

在 Finder 的 Tern 位置中右键文件或文件夹，选择 **创建分享链接…**。
每次分享都会打开策略窗口：

- 分享密码（可选，默认无密码）；
- 有效期（默认 24 小时，可选 1 小时 / 7 天 / 30 天 / 永久）。

确认后菜单栏 App 创建分享链接并复制到剪贴板。分享由服务端
`POST /api/shares` 完成，链接是公开链接，可发给其他人。

### 剪贴板

菜单栏 Tern 菜单：

- **发送剪贴板到 Tern**：把当前文本剪贴板发送到服务端；
- **从 Tern 获取剪贴板**：把服务端最近一次文本写入本地剪贴板。

这是手动功能，不会自动监听剪贴板，也不会自动覆盖剪贴板。

## 排障

### Finder 没有出现 Tern

- 设置页点「在 Finder 中启用 Tern」；
- 系统设置 → 通用 → 登录项与扩展 → 文件提供程序，启用 Tern；
- 确认 `TernFileProvider.appex` 在 `Tern.app/Contents/PlugIns/`；
- 看 `~/Library/Logs/Tern.log` 和 Console.app 中 `TernFileProvider` 日志。

### 网页上传后 Finder 长时间不更新

- 确认 Tern 菜单栏 App 正在运行；
- 确认「登录时自动启动」开启；
- 查看日志中是否有 `fileprovider watcher: change detected`；
- 服务端版本必须包含 `/api/sync/watch`（1.2.1+）。

### 签名/注册失败

```text
No profiles for 'com.tern.menubar.FileProvider'
```

- Xcode → Settings → Accounts 确认 Apple ID 已登录；
- 两个 target 使用同一个 Team；
- 不要启用 App Groups（Personal Team 不支持）；
- 需要 `TEAM=... ./build-xcode.sh`。

### 文件是只读

确认使用的是最新扩展；`TernItem.capabilities` 必须包含
`allowsWriting` / `allowsRenaming` / `allowsDeleting`。

## 发布

正式分发需要付费 Apple Developer Program：

```bash
cd macos
TEAM=... APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_PASSWORD=... ./package-release.sh
```

`package-release.sh` 会归档、导出 Developer ID 应用、公证并 staple，输出
`dist/Tern-FileProvider-<version>.zip`。没有付费账号时只能本机签名使用。
