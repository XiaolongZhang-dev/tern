# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.4] - 2026-10-27

### Fixed

- macOS "最近同步时间" now refreshes every 3 seconds while the menu is open,
  matching the Windows client cadence. The timer runs in the common RunLoop
  mode so menu tracking does not suspend it.

## [1.4.3] - 2026-10-27

### Changed

- "最近同步时间" now means the last successful *check*, including a
  long-poll timeout with no changes. Pausing sync freezes the timestamp.

## [1.4.2] - 2026-10-27

### Changed

- macOS and Windows tray menus now display a relative "最近同步时间"
  (seconds/minutes/hours/days/weeks/months/years).
- Removed redundant header/status lines from both menus and aligned the
  remaining menu items across macOS and Windows.

## [Unreleased]

### Planned

See [ROADMAP.md](ROADMAP.md) for the prioritized backlog.

## [1.4.4] - 2026-10-27

### Fixed

- macOS "最近同步时间" now refreshes every 3 seconds while the menu is open,
  matching the Windows client cadence. The timer runs in the common RunLoop
  mode so menu tracking does not suspend it.

## [1.4.3] - 2026-10-27

### Changed

- "最近同步时间" now means the last successful *check*, including a
  long-poll timeout with no changes. Pausing sync freezes the timestamp.

## [1.4.2] - 2026-10-27

### Changed

- macOS and Windows tray menus now display a relative "最近同步时间"
  (seconds/minutes/hours/days/weeks/months/years).
- Removed redundant header/status lines from both menus and aligned the
  remaining menu items across macOS and Windows.

## [1.4.1] - 2026-10-24

### Security

- Upgraded `body-parser` and `multer` to patched releases (0 known `npm audit`
  vulnerabilities in production dependencies).
- HSTS enabled on the NAS reverse proxy.
- Session cookies are now marked `Secure` behind the reverse proxy
  (`TRUST_PROXY=true`, `COOKIE_SECURE=true`).

## [1.4.0] - 2026-10-24

### Added

- File version history: every raw overwrite snapshots the previous blob, with
  listing, download and restore APIs plus a web UI.
- Admin full backup download (consistent SQLite snapshot + storage ZIP) and a
  restore script.
- Resumable chunked upload API and automatic chunked uploads for large files
  in the web UI.
- SHA-256 metadata for uploaded files and version snapshots.
- Configurable version retention (`VERSION_RETENTION_DAYS`,
  `MAX_VERSIONS_PER_FILE`) and upload chunk size (`UPLOAD_CHUNK_BYTES`).
- macOS and Windows new-file uploads use the resumable API for files >= 32 MiB
  (existing-file edits remain atomic If-Match PUTs).
- Windows checks GitHub Releases and can download/run the new installer;
  macOS shows the release download page.

## [1.3.1] - 2026-10-23

### Fixed

- macOS Finder share actions no longer trigger a Keychain password prompt.

### Changed

- Release version aligned with the macOS 1.3.1 build; Windows remains 1.2.0.

## [1.3.0] - 2026-10-23

### Added

- Server clipboard API (`GET/PUT /api/clipboard`) for manual cross-device
  text clipboard transfer.
- macOS Finder "创建分享链接…" File Provider action with a per-share policy
  dialog (password optional, expiry defaults to 24 hours).
- macOS menu-bar "发送剪贴板到 Tern" and "从 Tern 获取剪贴板" actions.
- Windows Explorer "创建 Tern 分享链接…" context menu and per-share policy
  dialog.
- Windows tray clipboard send/fetch actions.

## [Windows 1.1.1] - 2026-10-23

### Added

- Windows sync state persists the `/api/sync/changes` cursor and node cache, so
  restarts and watcher updates use incremental deltas instead of refetching the
  full tree.
- Durable folder operation queue for local folder create/rename/delete, retried
  after offline periods.
- Windows `NetworkAvailabilityChanged`, `NetworkAddressChanged` and
  FileSystemWatcher events for immediate reconnect and local uploads.

### Fixed

- Local folder rename/delete now reaches the server; remote folder cleanup
  removes empty local directories.

## [Windows 1.1.0] - 2026-10-23

### Added

- Windows client rebuilt on the **Windows Cloud Files API**: Explorer cloud
  location, on-demand hydration, offline reads/writes, native pin state,
  conflict copies and optional `T:` drive.
- Long-poll `/api/sync/watch` watcher so web/other-client uploads appear in
  Explorer without reopening folders.
- Windows `NetworkAvailabilityChanged` / `NetworkAddressChanged` listeners and
  a FileSystemWatcher for immediate reconnect and local-change uploads.
- On-demand download and offline queue through the Tern REST API.

### Changed

- Removed Windows WebDAV mapping, WebClient dependency, large-file registry
  workaround and related diagnostics.
- Windows sync folder defaults to `%USERPROFILE%\Tern`; `T:` is optional and
  implemented with `subst`.
- Uninstall cleanup unregisters the Cloud Files sync root.

## [1.2.1] - 2026-10-23

### Added

- Server `GET /api/sync/watch` long-poll endpoint so the macOS menu-bar app can wake File Provider when the web UI or another client changes the tree.
- macOS File Provider watcher: web uploads appear in Finder in about a second without reopening folders.
- Updated NAS image and menu-bar app to 1.2.1.

### Changed

- File Provider folder enumeration now pulls incremental changes on every open.
- macOS client no longer mounts WebDAV: removed `MountClient`, the `mount-smoke` CLI, WebDAV diagnostics and the auto-mount/login-remount path. WebDAV remains server-side for Windows/rclone.
- Personal Team build no longer requires App Groups; connection metadata and status use shared Keychain items.
- Login startup is retained for the watcher; the app is File Provider-only.

## [1.2.0] - 2026-10-23

### Added

- Server `GET /api/sync/changes` append-only change feed with bootstrap snapshots, incremental upserts and tombstones, plus integration tests.
- Server `PUT /api/nodes/:id/content` with `If-Match`/ETag conflict detection, and `clientId` support for stable offline-created nodes.
- macOS File Provider Phase 3: online create/upload/modify/move/delete, client-supplied IDs, durable offline write queue, automatic conflict copies, image thumbnails, sync status, Keep Downloaded / Remove Download actions, WebDAV-mount migration, NWPathMonitor network recovery and a Developer ID/notarization script.
- Windows 10/11 x64 tray client that maps Tern as a drive letter (`Tern (T:)`) via WebDAV, with Credential Manager storage, auto-connect, drive-letter selection, WebClient diagnostics and a Windows build workflow.
- GitHub Actions workflow to publish multi-arch (`amd64`/`arm64`) Docker images to
  Docker Hub on `v*` tags, plus a `docker-compose.hub.yml` deployment path for the
  prebuilt image.

### Notes

- The Docker image is built from the server/web tree; macOS File Provider code remains
  an experimental source build until a signed notarized client is published.

## [1.1.1] - 2026-10-19

### Fixed

- macOS: clicking **Settings…** in the menu bar now always opens a dedicated
  AppKit settings window. The previous implementation relied on a private
  SwiftUI `showSettingsWindow:` action that could return success without showing
  a window on recent macOS releases.
- macOS: the settings window is explicitly activated and ordered to the front
  when opened.

## [1.1.0] - 2026-10-19

Tern is the new name of the project. This release is the first public Tern
release.

### Added

- Docker Compose deployment: one Node.js container serving the REST API, WebDAV
  and the compiled React SPA, with bind-mounted `./data` storage.
- Multi-stage image build (web build + production dependencies) on Node 24
  Alpine; runs as a non-root UID via `DATA_UID`/`DATA_GID`, includes healthcheck.
- Authentication and accounts: first-run setup, scrypt password hashing,
  HttpOnly session cookies, admin member management with per-user quotas.
- File management: folders, multi-file streaming uploads, downloads, Range
  requests, image previews, rename/move/copy, star, search, recent, overview,
  soft-delete trash with restore/permanent delete/empty, folder ZIP downloads.
- Share links with optional scrypt-hashed passwords, expiry and download
  counters; public share page with password gate and inline preview.
- Finder-compatible WebDAV at `/dav` and `/Tern`:
  DAV 1,2, PROPFIND, PROPPATCH, GET/HEAD with Range, PUT, MKCOL, DELETE, COPY,
  MOVE, LOCK/UNLOCK.
- React 19 + TypeScript web client with light/dark themes, responsive layout,
  drag-and-drop upload queue with progress, previews, dialogs, toasts and admin
  screens; no external CDN/font dependencies.
- SwiftUI macOS menu-bar client `Tern.app` that mounts the WebDAV endpoint via
  NetFS at `/Volumes/Tern`, stores passwords in Keychain, supports launch at
  login, clean unmount, diagnostics and a `mount-smoke` CLI.
- Documentation: deployment (Synology/QNAP/Unraid, HTTPS proxy), macOS client,
  architecture, API contract, English README and UI screenshots.
- 35 server integration tests covering auth, file operations, shares, quotas and
  WebDAV; CI for server, web, Docker and macOS builds.
- Open-source infrastructure: CONTRIBUTING, CODE_OF_CONDUCT, SECURITY,
  CHANGELOG, ROADMAP, issue/PR templates and Dependabot.

### Changed

- Rebranded to **Tern**:
  - Docker image/container/project: `tern`;
  - WebDAV path: `/Tern`;
  - macOS app: `Tern.app`, bundle id `com.tern.menubar`, volume `/Volumes/Tern`;
  - default server name and UI copy use Tern.
- macOS users upgrading from the pre-release build must re-enter the server
  password because the Keychain service identifier changed.
- The macOS bundle is ad-hoc signed; see [docs/MAC.md](docs/MAC.md) for
  Gatekeeper instructions.

### Security

- Upload and WebDAV PUT size limits plus per-user quotas.
- Inline HTML/SVG/XML content is sandboxed via CSP; downloads keep attachments.
- Login and WebDAV Basic-auth rate limiting.
- macOS AppleDouble/metadata files are hidden from REST listings while remaining
  available to Finder over WebDAV.

[Unreleased]: https://github.com/XiaolongZhang-dev/tern/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/XiaolongZhang-dev/tern/releases/tag/v1.2.0
[1.1.1]: https://github.com/XiaolongZhang-dev/tern/releases/tag/v1.1.1
[1.1.0]: https://github.com/XiaolongZhang-dev/tern/releases/tag/v1.1.0
