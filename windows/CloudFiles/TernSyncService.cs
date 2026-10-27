using System.Diagnostics;
using System.Net.NetworkInformation;

namespace Tern.Windows;

public sealed record SyncProgress(string Message, int Files, int Folders, bool Done);

public sealed class TernSyncService : IAsyncDisposable
{
    private readonly string root;
    private readonly string dataDirectory;
    private TernBackendClient? backend;
    private CloudFilesProvider? provider;
    private CancellationTokenSource? lifetime;
    private Task? watcherTask;
    private Task? localTask;
    private int cursor;
    private string? driveLetter;
    private Dictionary<string, TernNode> nodes = new(StringComparer.Ordinal);
    private Dictionary<string, TernNode> nodesByPath = new(StringComparer.OrdinalIgnoreCase);
    private readonly SemaphoreSlim refreshLock = new(1, 1);
    private readonly SemaphoreSlim localWake = new(0, 1);
    private readonly SemaphoreSlim networkRefreshLock = new(1, 1);
    private readonly object folderQueueLock = new();
    private FileSystemWatcher? localWatcher;
    private bool networkSubscribed;
    private List<PendingFolderOperation> pendingFolderOperations = new();
    private string StatePath => Path.Combine(dataDirectory, "sync-state.json");
    private string FolderQueuePath => Path.Combine(dataDirectory, "pending-folders.json");

    public TernSyncService(string root, string dataDirectory)
    {
        this.root = Path.GetFullPath(root);
        this.dataDirectory = dataDirectory;
        Directory.CreateDirectory(this.root);
        AppPaths.EnsureDataDirectory();
    }

    public string Root => root;
    public bool IsRunning { get; private set; }
    public string? LastError { get; private set; }
    public DateTimeOffset? LastSyncAt { get; private set; }
    public string? DriveLetter => driveLetter;
    public event EventHandler<SyncProgress>? Progress;
    public event EventHandler? StateChanged;

    public async Task StartAsync(AppSettings settings, string password, CancellationToken cancellationToken = default)
    {
        await StopAsync().ConfigureAwait(false);
        LastError = null;
        LoadState();
        LoadFolderQueue();
        var server = ServerUrl.NormalizeOrThrow(settings.ServerUrl);
        backend = new TernBackendClient(server, settings.Username, password);
        await backend.LoginAsync(cancellationToken).ConfigureAwait(false);
        provider = new CloudFilesProvider(root, AppPaths.EnsureDataDirectory(), backend);
        provider.FileDownloaded += path => Log.Info("cloudfiles: hydrated " + path);
        await provider.RegisterAndConnectAsync().ConfigureAwait(false);
        lifetime = new CancellationTokenSource();
        await RefreshAsync(cancellationToken).ConfigureAwait(false);
        watcherTask = Task.Run(() => WatchLoopAsync(lifetime.Token));
        localTask = Task.Run(() => LocalLoopAsync(lifetime.Token));
        StartLocalWatcher();
        NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        networkSubscribed = true;
        WakeLocal();
        if (!string.IsNullOrWhiteSpace(settings.DriveLetter))
        {
            try
            {
                DriveLetterSubst.Map(settings.DriveLetter, root);
                driveLetter = settings.DriveLetter;
            }
            catch (Exception exception)
            {
                Log.Warn("盘符映射失败: " + exception.Message);
                driveLetter = null;
            }
        }
        IsRunning = true;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task StopAsync()
    {
        if (networkSubscribed)
        {
            NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
            NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
            networkSubscribed = false;
        }
        if (localWatcher is not null)
        {
            localWatcher.EnableRaisingEvents = false;
            localWatcher.Dispose();
            localWatcher = null;
        }
        if (provider is not null)
        {
            try { await provider.DisposeAsync().ConfigureAwait(false); } catch (Exception ex) { Log.Warn("cloudfiles dispose: " + ex.Message); }
            provider = null;
        }
        if (watcherTask is not null)
        {
            lifetime?.Cancel();
            try { await watcherTask.ConfigureAwait(false); } catch { }
            watcherTask = null;
        }
        if (localTask is not null)
        {
            try { await localTask.ConfigureAwait(false); } catch { }
            localTask = null;
        }
        lifetime?.Dispose();
        lifetime = null;
        if (backend is not null)
        {
            await backend.DisposeAsync().ConfigureAwait(false);
            backend = null;
        }
        if (driveLetter is not null)
        {
            DriveLetterSubst.Unmap(driveLetter);
            driveLetter = null;
        }
        IsRunning = false;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        await refreshLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (provider is null || backend is null) return;
            var oldFolderPaths = nodesByPath
                .Where(pair => pair.Value.IsFolder)
                .Select(pair => pair.Key)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            var page = await backend.GetChangesAsync(cursor, cancellationToken: cancellationToken).ConfigureAwait(false);
            if (page.Reset) nodes.Clear();
            ApplyChanges(page);
            cursor = page.Cursor;
            while (page.HasMore)
            {
                cancellationToken.ThrowIfCancellationRequested();
                page = await backend.GetChangesAsync(cursor, cancellationToken: cancellationToken).ConfigureAwait(false);
                if (page.Reset) nodes.Clear();
                ApplyChanges(page);
                cursor = page.Cursor;
            }
            SaveState();

            var paths = BuildPaths(nodes);
            nodesByPath = paths.ToDictionary(pair => pair.Value, pair => nodes[pair.Key], StringComparer.OrdinalIgnoreCase);
            var folders = paths.Where(pair => nodes[pair.Key].IsFolder)
                .OrderBy(pair => pair.Value.Count(c => c == '/'))
                .ToArray();
            foreach (var (_, path) in folders)
            {
                if (!string.IsNullOrEmpty(path))
                    Directory.CreateDirectory(Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar)));
            }

            var entries = paths
                .Where(pair => !nodes[pair.Key].IsFolder)
                .Select(pair =>
                {
                    var node = nodes[pair.Key];
                    return new ManifestEntry
                    {
                        RelativePath = pair.Value,
                        Kind = "file",
                        CourseId = node.ParentId ?? string.Empty,
                        SourceId = node.Id,
                        Revision = node.Etag ?? "0",
                        Size = node.Size,
                        UpdatedAt = node.UpdatedAt,
                        ContentType = node.Mime,
                    };
                })
                .ToArray();
            var manifest = new Manifest
            {
                SchemaVersion = 1,
                GeneratedAt = DateTimeOffset.UtcNow,
                Entries = entries,
            };
            var summary = await new ManifestReconciler(provider).ReconcileAsync(manifest, cancellationToken).ConfigureAwait(false);

            // Remove directories that belonged to a folder deleted/renamed remotely.
            foreach (var old in oldFolderPaths)
            {
                if (nodesByPath.ContainsKey(old)) continue;
                if (string.IsNullOrWhiteSpace(old)) continue;
                var directory = Path.Combine(root, old.Replace('/', Path.DirectorySeparatorChar));
                try
                {
                    if (Directory.Exists(directory) && !Directory.EnumerateFileSystemEntries(directory).Any())
                        Directory.Delete(directory);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    // The shell may still hold a handle; the next refresh will retry.
                }
            }

            LastError = null;
            LastSyncAt = DateTimeOffset.Now;
            Log.Info($"cloudfiles refresh: cursor={cursor} created={summary.Created} updated={summary.Updated} removed={summary.Removed} conflicts={summary.Conflicts} unchanged={summary.Unchanged}");
            Progress?.Invoke(this, new SyncProgress("已同步", entries.Length, folders.Length, true));
        }
        catch (Exception exception)
        {
            LastError = exception.Message;
            Log.Warn("cloudfiles refresh failed: " + exception.Message);
            throw;
        }
        finally
        {
            refreshLock.Release();
        }
    }

    private void ApplyChanges(TernChanges page)
    {
        foreach (var change in page.Changes)
        {
            if (change.Deleted)
            {
                nodes.Remove(change.Id);
            }
            else if (change.Node is { } node)
            {
                nodes[node.Id] = node;
            }
        }
    }

    private void LoadState()
    {
        nodes.Clear();
        cursor = 0;
        try
        {
            if (!File.Exists(StatePath)) return;
            var state = System.Text.Json.JsonSerializer.Deserialize<SyncState>(File.ReadAllText(StatePath));
            if (state is null) return;
            cursor = Math.Max(0, state.Cursor);
            foreach (var node in state.Nodes ?? new List<TernNode>())
                nodes[node.Id] = node;
            Log.Info($"cloudfiles state: cursor={cursor} nodes={nodes.Count}");
        }
        catch (Exception exception)
        {
            Log.Warn("cloudfiles state load failed: " + exception.Message);
            nodes.Clear();
            cursor = 0;
        }
    }

    private void SaveState()
    {
        try
        {
            var state = new SyncState { Cursor = cursor, Nodes = nodes.Values.ToList() };
            File.WriteAllText(StatePath, System.Text.Json.JsonSerializer.Serialize(state, new System.Text.Json.JsonSerializerOptions { WriteIndented = false }));
        }
        catch (Exception exception)
        {
            Log.Warn("cloudfiles state save failed: " + exception.Message);
        }
    }

    private void LoadFolderQueue()
    {
        try
        {
            pendingFolderOperations = File.Exists(FolderQueuePath)
                ? System.Text.Json.JsonSerializer.Deserialize<List<PendingFolderOperation>>(File.ReadAllText(FolderQueuePath)) ?? new()
                : new();
        }
        catch
        {
            pendingFolderOperations = new();
        }
    }

    private void SaveFolderQueue()
    {
        lock (folderQueueLock)
        {
            try
            {
                File.WriteAllText(FolderQueuePath, System.Text.Json.JsonSerializer.Serialize(pendingFolderOperations));
            }
            catch (Exception exception)
            {
                Log.Warn("folder queue save failed: " + exception.Message);
            }
        }
    }

    private void EnqueueFolderOperation(string kind, string oldPath, string newPath)
    {
        lock (folderQueueLock)
        {
            if (pendingFolderOperations.Any(op => op.Kind == kind && op.OldPath == oldPath && op.NewPath == newPath))
                return;
            pendingFolderOperations.Add(new PendingFolderOperation
            {
                Kind = kind,
                OldPath = oldPath,
                NewPath = newPath,
                CreatedAt = DateTimeOffset.UtcNow,
            });
            SaveFolderQueue();
        }
        WakeLocal();
    }

    private sealed class SyncState
    {
        public int Cursor { get; set; }
        public List<TernNode>? Nodes { get; set; }
    }

    private sealed class PendingFolderOperation
    {
        public string Kind { get; set; } = "";
        public string OldPath { get; set; } = "";
        public string NewPath { get; set; } = "";
        public DateTimeOffset CreatedAt { get; set; }
    }

    private async Task WatchLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                if (backend is null) return;
                var updated = await backend.WatchAsync(cursor, cancellationToken).ConfigureAwait(false);
                if (updated != cursor)
                {
                    await RefreshAsync(cancellationToken).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception)
            {
                LastError = exception.Message;
                Log.Warn("cloudfiles watcher: " + exception.Message);
                try { await Task.Delay(5000, cancellationToken).ConfigureAwait(false); } catch { return; }
            }
        }
    }

    private void StartLocalWatcher()
    {
        try
        {
            localWatcher = new FileSystemWatcher(root)
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName
                    | NotifyFilters.DirectoryName
                    | NotifyFilters.LastWrite
                    | NotifyFilters.Size,
            };
            localWatcher.Created += (_, _) => WakeLocal();
            localWatcher.Changed += (_, _) => WakeLocal();
            localWatcher.Deleted += (_, e) =>
            {
                var relative = RelativePath(e.FullPath);
                if (nodesByPath.TryGetValue(relative, out var node) && node.IsFolder)
                    EnqueueFolderOperation("delete", relative, "");
                WakeLocal();
            };
            localWatcher.Renamed += (_, e) =>
            {
                if (Directory.Exists(e.FullPath))
                {
                    var oldRelative = RelativePath(e.OldFullPath);
                    var newRelative = RelativePath(e.FullPath);
                    if (nodesByPath.TryGetValue(oldRelative, out var node) && node.IsFolder)
                        EnqueueFolderOperation("rename", oldRelative, newRelative);
                }
                WakeLocal();
            };
            localWatcher.Error += (_, _) => WakeLocal();
            localWatcher.EnableRaisingEvents = true;
        }
        catch (Exception exception)
        {
            Log.Warn("local watcher failed: " + exception.Message);
        }
    }

    private void WakeLocal()
    {
        try
        {
            if (localWake.CurrentCount == 0) localWake.Release();
        }
        catch (SemaphoreFullException)
        {
            // A wake-up is already pending.
        }
    }

    private void OnNetworkChanged(object? sender, EventArgs e)
    {
        if (!IsRunning) return;
        Log.Info("network: change detected; refreshing sync");
        _ = Task.Run(async () =>
        {
            await networkRefreshLock.WaitAsync().ConfigureAwait(false);
            try
            {
                await Task.Delay(700).ConfigureAwait(false);
                if (backend is not null)
                {
                    try { await backend.LoginAsync().ConfigureAwait(false); }
                    catch (Exception exception) { Log.Warn("network: login after change failed: " + exception.Message); }
                }
                try { await RefreshAsync().ConfigureAwait(false); }
                catch (Exception exception) { Log.Warn("network: refresh after change failed: " + exception.Message); }
                WakeLocal();
                StateChanged?.Invoke(this, EventArgs.Empty);
            }
            finally
            {
                networkRefreshLock.Release();
            }
        });
    }

    private string RelativePath(string absolute)
    {
        try { return Path.GetRelativePath(root, absolute).Replace('\\', '/'); }
        catch { return ""; }
    }

    private async Task ProcessFolderOperationsAsync(CancellationToken cancellationToken)
    {
        if (backend is null || provider is null) return;
        PendingFolderOperation[] operations;
        lock (folderQueueLock) operations = pendingFolderOperations.ToArray();
        foreach (var operation in operations)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                if (operation.Kind == "rename")
                {
                    if (!nodesByPath.TryGetValue(operation.OldPath, out var node) || !node.IsFolder) { RemoveFolderOperation(operation); continue; }
                    var parent = ParentPath(operation.NewPath);
                    nodesByPath.TryGetValue(parent, out var parentNode);
                    var updated = await backend.RenameAsync(
                        node.Id,
                        Path.GetFileName(operation.NewPath),
                        parentNode?.Id,
                        moveToRoot: parent.Length == 0,
                        cancellationToken).ConfigureAwait(false);
                    nodes[node.Id] = updated;
                    await provider.RemapPathPrefixAsync(operation.OldPath, operation.NewPath, cancellationToken).ConfigureAwait(false);
                    RemoveFolderOperation(operation);
                    await RefreshAsync(cancellationToken).ConfigureAwait(false);
                    Log.Info("cloudfiles: renamed folder " + operation.OldPath + " -> " + operation.NewPath);
                }
                else if (operation.Kind == "delete")
                {
                    if (!nodesByPath.TryGetValue(operation.OldPath, out var node) || !node.IsFolder) { RemoveFolderOperation(operation); continue; }
                    await backend.DeleteAsync(node.Id, cancellationToken).ConfigureAwait(false);
                    await provider.RemovePathPrefixAsync(operation.OldPath, cancellationToken).ConfigureAwait(false);
                    RemoveFolderOperation(operation);
                    await RefreshAsync(cancellationToken).ConfigureAwait(false);
                    Log.Info("cloudfiles: deleted folder " + operation.OldPath);
                }
                else
                {
                    RemoveFolderOperation(operation);
                }
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                Log.Warn("cloudfiles folder op failed " + operation.Kind + " " + operation.OldPath + ": " + exception.Message);
            }
        }
    }

    private void RemoveFolderOperation(PendingFolderOperation operation)
    {
        lock (folderQueueLock)
        {
            pendingFolderOperations.Remove(operation);
            SaveFolderQueue();
        }
    }

    private async Task LocalLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await localWake.WaitAsync(TimeSpan.FromSeconds(25), cancellationToken).ConfigureAwait(false);
                // Coalesce bursts from editors and Cloud Files hydration.
                await Task.Delay(250, cancellationToken).ConfigureAwait(false);
                await UploadLocalChangesAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception)
            {
                LastError = exception.Message;
                Log.Warn("cloudfiles local sync: " + exception.Message);
            }
        }
    }

    private async Task UploadLocalChangesAsync(CancellationToken cancellationToken)
    {
        if (provider is null || backend is null) return;
        await ProcessFolderOperationsAsync(cancellationToken).ConfigureAwait(false);
        // Snapshot() prunes the index for paths that disappeared. Capture the
        // managed set first so a local delete/rename is still reported to the
        // server instead of silently disappearing from the index.
        var managedBefore = provider.ManagedPaths();
        await UploadLocalFoldersAsync(cancellationToken).ConfigureAwait(false);
        var local = await provider.SnapshotAsync(cancellationToken).ConfigureAwait(false);
        var present = new HashSet<string>(local.Select(item => item.RelativePath), StringComparer.OrdinalIgnoreCase);
        foreach (var entry in local)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!entry.IsHydrated) continue;
            var relative = entry.RelativePath;
            if (relative.StartsWith("Local Conflicts/", StringComparison.OrdinalIgnoreCase)) continue;
            if (IsIgnored(relative)) continue;
            var absolute = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(absolute)) continue;

            if (!entry.IsManaged)
            {
                var parent = ParentPath(relative);
                nodesByPath.TryGetValue(parent, out var parentNode);
                if (!string.IsNullOrEmpty(parent) && parentNode is null) continue;
                var node = await backend.UploadFileAsync(parentNode?.Id, Path.GetFileName(relative), absolute, MimeFor(relative), cancellationToken).ConfigureAwait(false);
                var remote = EntryFor(node, relative);
                await provider.AdoptUploadedAsync(relative, remote, convertToPlaceholder: true, cancellationToken).ConfigureAwait(false);
                nodesByPath[relative] = node;
                Log.Info("cloudfiles: uploaded " + relative);
                continue;
            }

            if (entry.IsInSync || entry.Identity is null) continue;
            var nodeId = entry.Identity.SourceId;
            if (!nodes.TryGetValue(nodeId, out var current)) continue;
            var bytes = await File.ReadAllBytesAsync(absolute, cancellationToken).ConfigureAwait(false);
            try
            {
                var updated = await backend.UpdateContentAsync(nodeId, bytes, entry.Identity.Revision, cancellationToken).ConfigureAwait(false);
                var remote = EntryFor(updated, relative);
                await provider.MarkUploadedAsync(relative, remote, cancellationToken).ConfigureAwait(false);
                nodesByPath[relative] = updated;
                Log.Info("cloudfiles: updated " + relative);
            }
            catch (TernBackendException exception) when (exception.Code == "conflict")
            {
                await ResolveConflictAsync(relative, bytes, current, cancellationToken).ConfigureAwait(false);
            }
        }

        // A path that disappeared from the managed index is a local delete or rename.
        foreach (var managed in managedBefore)
        {
            if (present.Contains(managed)) continue;
            if (IsIgnored(managed)) continue;
            if (!nodesByPath.TryGetValue(managed, out var node)) continue;
            try
            {
                await backend.DeleteAsync(node.Id, cancellationToken).ConfigureAwait(false);
                await provider.RemoveManagedAsync(managed, cancellationToken).ConfigureAwait(false);
                nodesByPath.Remove(managed);
                Log.Info("cloudfiles: deleted " + managed);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                Log.Warn("cloudfiles: delete failed " + managed + ": " + exception.Message);
            }
        }
    }

    private async Task UploadLocalFoldersAsync(CancellationToken cancellationToken)
    {
        if (backend is null) return;
        if (!Directory.Exists(root)) return;
        var directories = Directory.EnumerateDirectories(root, "*", SearchOption.AllDirectories)
            .Where(path => !Path.GetRelativePath(root, path).StartsWith("Local Conflicts", StringComparison.OrdinalIgnoreCase))
            .OrderBy(path => path.Count(c => c == Path.DirectorySeparatorChar))
            .ToArray();
        foreach (var directory in directories)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var relative = Path.GetRelativePath(root, directory).Replace('\\', '/');
            if (nodesByPath.ContainsKey(relative)) continue;
            lock (folderQueueLock)
            {
                if (pendingFolderOperations.Any(op => op.Kind == "rename" && op.NewPath.Equals(relative, StringComparison.OrdinalIgnoreCase)))
                    continue;
            }
            var parent = ParentPath(relative);
            nodesByPath.TryGetValue(parent, out var parentNode);
            var node = await backend.CreateFolderAsync(parentNode?.Id, Path.GetFileName(relative), cancellationToken).ConfigureAwait(false);
            nodesByPath[relative] = node;
            nodes[node.Id] = node;
            Log.Info("cloudfiles: created folder " + relative);
        }
    }

    private async Task ResolveConflictAsync(
        string relative,
        byte[] localData,
        TernNode current,
        CancellationToken cancellationToken)
    {
        if (backend is null || provider is null) return;
        var parent = ParentPath(relative);
        nodesByPath.TryGetValue(parent, out var parentNode);
        var name = Path.GetFileNameWithoutExtension(relative);
        var extension = Path.GetExtension(relative);
        var conflict = $"{name} (conflicted copy){extension}";
        await backend.UploadAsync(parentNode?.Id, conflict, localData, MimeFor(relative), cancellationToken).ConfigureAwait(false);
        var remoteData = await backend.DownloadAsync(current.Id, cancellationToken).ConfigureAwait(false);
        var absolute = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
        await File.WriteAllBytesAsync(absolute, remoteData, cancellationToken).ConfigureAwait(false);
        await provider.MarkUploadedAsync(relative, EntryFor(current, relative), cancellationToken).ConfigureAwait(false);
        Log.Warn("cloudfiles: conflict copy created for " + relative);
        Progress?.Invoke(this, new SyncProgress("已生成冲突副本：" + conflict, 0, 0, true));
    }

    private static string ParentPath(string relative)
    {
        var index = relative.LastIndexOf('/');
        return index <= 0 ? string.Empty : relative[..index];
    }

    private static bool IsIgnored(string relative)
    {
        var name = Path.GetFileName(relative);
        return name.Equals(".DS_Store", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("._", StringComparison.Ordinal)
            || name.EndsWith("~", StringComparison.Ordinal)
            || name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase);
    }

    private static string MimeFor(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".txt" => "text/plain",
        ".md" => "text/markdown",
        ".json" => "application/json",
        ".pdf" => "application/pdf",
        ".png" => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".mp4" => "video/mp4",
        ".mp3" => "audio/mpeg",
        ".zip" => "application/zip",
        _ => "application/octet-stream",
    };

    private static ManifestEntry EntryFor(TernNode node, string relative) => new()
    {
        RelativePath = relative,
        Kind = "file",
        CourseId = node.ParentId ?? string.Empty,
        SourceId = node.Id,
        Revision = node.Etag ?? "0",
        Size = node.Size,
        UpdatedAt = node.UpdatedAt,
        ContentType = node.Mime,
    };

    private Dictionary<string, string> BuildPaths(IReadOnlyDictionary<string, TernNode> map)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var node in map.Values)
        {
            var parts = new List<string>();
            var current = node;
            var guard = 0;
            while (current is not null && guard++ < 256)
            {
                parts.Add(current.Name);
                if (string.IsNullOrWhiteSpace(current.ParentId) || !map.TryGetValue(current.ParentId, out var parent))
                    break;
                current = parent;
            }
            parts.Reverse();
            result[node.Id] = string.Join('/', parts);
        }
        return result;
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    public static void CleanupForUninstall(AppSettings settings)
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(settings.SyncFolder))
                CloudFilesProvider.PrepareForUninstall(settings.SyncFolder, AppPaths.EnsureDataDirectory());
        }
        catch (Exception exception)
        {
            Log.Warn("uninstall cleanup: " + exception.Message);
        }
        try
        {
            if (!string.IsNullOrWhiteSpace(settings.DriveLetter))
                DriveLetterSubst.Unmap(settings.DriveLetter);
        }
        catch { }
    }
}

public static class DriveLetterSubst
{
    public static IEnumerable<string> AvailableLetters()
    {
        var used = new HashSet<char>();
        try
        {
            foreach (var drive in DriveInfo.GetDrives())
            {
                var name = drive.Name.TrimEnd('\\');
                if (name.Length > 0) used.Add(char.ToUpperInvariant(name[0]));
            }
        }
        catch { }
        foreach (var letter in "TUVWXYZ")
        {
            if (!used.Contains(letter)) yield return letter.ToString();
        }
        foreach (var letter in "DEFGHIJKLMNOPQRS")
        {
            if (!used.Contains(letter)) yield return letter.ToString();
        }
    }

    public static void Map(string driveLetter, string target)
    {
        var letter = Normalize(driveLetter);
        var process = Process.Start(new ProcessStartInfo("subst.exe", $"{letter}: \"{target}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        process?.WaitForExit(5000);
        if (Directory.Exists(letter + ":\\") == false)
            throw new InvalidOperationException("无法创建 " + letter + ": 盘符。");
    }

    public static void Unmap(string driveLetter)
    {
        var letter = Normalize(driveLetter);
        try
        {
            var process = Process.Start(new ProcessStartInfo("subst.exe", $"{letter}: /D")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            process?.WaitForExit(3000);
        }
        catch { }
    }

    private static string Normalize(string value)
    {
        var letter = (value ?? "").Trim().TrimEnd(':').ToUpperInvariant();
        return letter.Length == 1 && letter[0] >= 'D' && letter[0] <= 'Z' ? letter : "T";
    }
}
