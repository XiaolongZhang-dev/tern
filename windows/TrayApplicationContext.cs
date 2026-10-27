using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace Tern.Windows;

public sealed class TrayApplicationContext : ApplicationContext
{
    private readonly SettingsStore _store = new();
    private readonly NotifyIcon _notifyIcon;
    private readonly ToolStripMenuItem _lastSyncItem;
    private readonly ToolStripMenuItem _connectItem;
    private readonly ToolStripMenuItem _openItem;
    private readonly System.Windows.Forms.Timer _stateTimer;
    private readonly System.Windows.Forms.Timer _startupTimer;
    private readonly System.Windows.Forms.Timer _updateTimer;
    private readonly TernSyncService _sync;

    private AppSettings _settings;
    private string? _savedPassword;
    private SettingsForm? _settingsForm;
    private bool _busy;
    private bool? _lastRunning;
    private string? _lastError;

    public TrayApplicationContext(string[] args)
    {
        _settings = _store.Load();
        ShellContextMenu.Register();
        _savedPassword = HasCredentials(_settings) ? CredentialStore.Load(_settings.ServerUrl, _settings.Username) : null;
        _sync = new TernSyncService(_settings.SyncFolder, AppPaths.EnsureDataDirectory());
        _sync.Progress += (_, progress) => Log.Info("sync: " + progress.Message);
        _sync.StateChanged += (_, _) => UpdateMenu();

        _lastSyncItem = new ToolStripMenuItem("最近同步时间：尚未同步") { Enabled = false };
        _connectItem = new ToolStripMenuItem("启用同步", null, async (_, _) => await ToggleAsync(true));
        _openItem = new ToolStripMenuItem("打开 Tern", null, (_, _) => OpenLocation()) { Enabled = false };

        var menu = new ContextMenuStrip();
        menu.Items.Add(_lastSyncItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_connectItem);
        menu.Items.Add(_openItem);
        menu.Items.Add(new ToolStripMenuItem("设置…", null, (_, _) => ShowSettings()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("发送剪贴板到 Tern", null, async (_, _) => await SendClipboardAsync()));
        menu.Items.Add(new ToolStripMenuItem("从 Tern 获取剪贴板", null, async (_, _) => await FetchClipboardAsync()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("复制服务器地址", null, (_, _) => CopyServerAddress()));
        menu.Items.Add(new ToolStripMenuItem("打开日志", null, (_, _) => Log.OpenLog()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("退出 Tern", null, (_, _) => ExitApplication()));

        _notifyIcon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "Tern · 未启用",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _notifyIcon.DoubleClick += (_, _) =>
        {
            if (_sync.IsRunning) OpenLocation();
            else ShowSettings();
        };

        _stateTimer = new System.Windows.Forms.Timer { Interval = 3000 };
        _stateTimer.Tick += (_, _) => UpdateMenu();
        _stateTimer.Start();

        _updateTimer = new System.Windows.Forms.Timer { Interval = 6000 };
        _updateTimer.Tick += async (_, _) =>
        {
            _updateTimer.Stop();
            await CheckForUpdatesAsync();
        };
        _updateTimer.Start();

        _startupTimer = new System.Windows.Forms.Timer { Interval = 700 };
        _startupTimer.Tick += (_, _) =>
        {
            _startupTimer.Stop();
            _ = StartAsync();
        };
        _startupTimer.Start();

        UpdateMenu();
    }

    private async Task CheckForUpdatesAsync()
    {
        var update = await UpdateChecker.CheckAsync();
        if (update is null || _sync.IsRunning) return;
        var answer = MessageBox.Show(
            $"发现 Tern {update.Version} 新版本。\n\n是否下载并安装？",
            "Tern 更新", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (answer != DialogResult.Yes) return;
        try
        {
            Cursor.Current = Cursors.WaitCursor;
            var installer = await UpdateChecker.DownloadAsync(update);
            Cursor.Current = Cursors.Default;
            UpdateChecker.LaunchInstaller(installer);
            ExitThread();
        }
        catch (Exception exception)
        {
            Cursor.Current = Cursors.Default;
            Log.Warn("update install failed: " + exception.Message);
            MessageBox.Show("下载更新失败：" + exception.Message, "Tern 更新",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task StartAsync()
    {
        SyncLaunchSetting();
        if (!HasConfig(_settings))
        {
            ShowSettings();
            return;
        }

        var autostart = Environment.GetCommandLineArgs().Any(a =>
            string.Equals(a, "--autostart", StringComparison.OrdinalIgnoreCase));
        if (_settings.AutoConnect || autostart)
            await ToggleAsync(false);
    }

    private void SyncLaunchSetting()
    {
        try
        {
            if (_settings.LaunchAtLogin)
            {
                if (!StartupManager.IsEnabled()) StartupManager.SetEnabled(true);
            }
            else
            {
                StartupManager.SetEnabled(false);
            }
        }
        catch (Exception exception)
        {
            Log.Warn("同步开机启动设置失败：" + exception.Message);
        }
    }

    private static bool HasConfig(AppSettings settings) =>
        !string.IsNullOrWhiteSpace(settings.ServerUrl) && !string.IsNullOrWhiteSpace(settings.Username);

    private static bool HasCredentials(AppSettings settings) =>
        HasConfig(settings) && CredentialStore.Has(settings.ServerUrl, settings.Username);

    private static Icon LoadIcon()
    {
        try
        {
            var path = Environment.ProcessPath ?? Application.ExecutablePath;
            return Icon.ExtractAssociatedIcon(path) ?? SystemIcons.Application;
        }
        catch
        {
            return SystemIcons.Application;
        }
    }

    private async Task ToggleAsync(bool interactive)
    {
        if (_busy) return;
        if (_sync.IsRunning)
        {
            await DisconnectAsync(interactive);
            return;
        }

        if (!HasConfig(_settings))
        {
            ShowSettings();
            return;
        }
        _savedPassword ??= CredentialStore.Load(_settings.ServerUrl, _settings.Username);
        if (string.IsNullOrWhiteSpace(_savedPassword))
        {
            if (interactive) ShowSettings();
            else Notify("缺少密码", "请打开 Tern 设置，填写服务器密码。", ToolTipIcon.Warning);
            return;
        }

        _busy = true;
        UpdateMenu();
        try
        {
            await _sync.StartAsync(_settings, _savedPassword);
            _lastError = null;
            UpdateMenu();
            if (interactive) OpenLocation();
        }
        catch (Exception exception)
        {
            _lastError = exception.Message;
            Log.Error("启用同步失败：" + exception.Message);
            if (interactive)
                MessageBox.Show(exception.Message, "Tern 启用失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            else
                Notify("Tern 启用失败", exception.Message, ToolTipIcon.Error);
        }
        finally
        {
            _busy = false;
            UpdateMenu();
        }
    }

    private async Task DisconnectAsync(bool interactive)
    {
        if (_busy) return;
        _busy = true;
        UpdateMenu();
        try
        {
            await _sync.StopAsync();
        }
        catch (Exception exception)
        {
            Log.Warn("停止同步失败：" + exception.Message);
            if (interactive)
                MessageBox.Show(exception.Message, "Tern", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            _busy = false;
            UpdateMenu();
        }
    }

    private void UpdateMenu()
    {
        var running = _sync.IsRunning;
        if (_lastRunning != running || _lastError is not null)
        {
            Log.Info($"托盘状态：running={running}, root={_sync.Root}, drive={_sync.DriveLetter ?? "<none>"}, error={_lastError ?? "无"}");
            _lastRunning = running;
        }

        var location = _sync.DriveLetter is { Length: 1 } letter ? letter + ":" : _sync.Root;
        _lastSyncItem.Text = "最近同步时间：" + RelativeTime(_sync.LastSyncAt);
        _connectItem.Text = running ? "断开同步" : "启用同步";
        _connectItem.Enabled = !_busy;
        _openItem.Enabled = running;
        var text = running ? "Tern · " + location : "Tern · 未启用";
        _notifyIcon.Text = text.Length > 63 ? text[..63] : text;
    }

    private void CopyServerAddress()
    {
        try
        {
            if (string.IsNullOrWhiteSpace(_settings.ServerUrl))
            {
                Notify("Tern", "尚未配置服务器地址。", ToolTipIcon.Info);
                return;
            }
            Clipboard.SetText(_settings.ServerUrl);
            Notify("Tern", "服务器地址已复制。", ToolTipIcon.Info);
        }
        catch (Exception exception)
        {
            Log.Warn("copy server address failed: " + exception.Message);
        }
    }

    private static string RelativeTime(DateTimeOffset? timestamp)
    {
        if (timestamp is null) return "尚未同步";
        var seconds = Math.Max(0, (long)(DateTimeOffset.Now - timestamp.Value).TotalSeconds);
        if (seconds < 60) return Math.Max(1, seconds) + "秒前";
        var minutes = seconds / 60;
        if (minutes < 60) return minutes + "分前";
        var hours = minutes / 60;
        if (hours < 24) return hours + "小时前";
        var days = hours / 24;
        if (days < 7) return days + "天前";
        var weeks = days / 7;
        if (weeks < 5) return weeks + "周前";
        var months = days / 30;
        if (months < 12) return months + "月前";
        return (days / 365) + "年前";
    }

    private void OpenLocation()
    {
        try
        {
            var target = _sync.DriveLetter is { Length: 1 } letter && Directory.Exists(letter + ":\\")
                ? letter + ":\\"
                : _sync.Root;
            Directory.CreateDirectory(_sync.Root);
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception exception)
        {
            MessageBox.Show("无法打开 Tern：" + exception.Message, "Tern", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void ShowSettings()
    {
        if (_settingsForm is not null)
        {
            _settingsForm.Activate();
            return;
        }

        _savedPassword = HasConfig(_settings)
            ? CredentialStore.Load(_settings.ServerUrl, _settings.Username)
            : null;
        _settingsForm = new SettingsForm(_settings.Clone(), _savedPassword, !HasConfig(_settings));
        var result = _settingsForm.ShowDialog();
        _settingsForm.Dispose();
        _settingsForm = null;
        if (result != DialogResult.OK) return;

        _settings = _store.Load();
        ShellContextMenu.Register();
        _savedPassword = CredentialStore.Load(_settings.ServerUrl, _settings.Username);
        _ = AfterSettingsSavedAsync();
    }

    private async Task AfterSettingsSavedAsync()
    {
        if (_sync.IsRunning) await DisconnectAsync(false);
        SyncLaunchSetting();
        if (_settings.AutoConnect)
            await ToggleAsync(true);
        else
            UpdateMenu();
    }

    private async Task SendClipboardAsync()
    {
        try
        {
            if (!Clipboard.ContainsText())
            {
                Notify("Tern 剪贴板", "剪贴板里没有可发送的文本。", ToolTipIcon.Info);
                return;
            }
            var text = Clipboard.GetText();
            if (string.IsNullOrEmpty(text)) return;
            var (client, settings, password) = await CreateBackendAsync().ConfigureAwait(true);
            await using (client)
            {
                _ = password;
                await client.PutClipboardAsync(text, Environment.MachineName).ConfigureAwait(true);
            }
            Notify("Tern 剪贴板", "剪贴板已发送到 Tern。", ToolTipIcon.Info);
        }
        catch (Exception exception)
        {
            Log.Error("send clipboard failed: " + exception);
            Notify("Tern 剪贴板发送失败", exception.Message, ToolTipIcon.Error);
        }
    }

    private async Task FetchClipboardAsync()
    {
        try
        {
            var (client, settings, password) = await CreateBackendAsync().ConfigureAwait(true);
            await using (client)
            {
                _ = password;
                var clipboard = await client.GetClipboardAsync().ConfigureAwait(true);
                if (clipboard is null)
                {
                    Notify("Tern 剪贴板", "Tern 上还没有保存的剪贴板内容。", ToolTipIcon.Info);
                    return;
                }
                Clipboard.SetText(clipboard.Text);
                Notify("Tern 剪贴板", clipboard.Device is { Length: > 0 }
                    ? $"已获取来自 {clipboard.Device} 的剪贴板内容。"
                    : "已获取 Tern 剪贴板内容。", ToolTipIcon.Info);
            }
        }
        catch (Exception exception)
        {
            Log.Error("fetch clipboard failed: " + exception);
            Notify("Tern 剪贴板获取失败", exception.Message, ToolTipIcon.Error);
        }
    }

    private async Task<(TernBackendClient client, AppSettings settings, string password)> CreateBackendAsync()
    {
        if (!HasConfig(_settings))
            throw new InvalidOperationException("Tern 尚未配置服务器和账号。");
        _savedPassword ??= CredentialStore.Load(_settings.ServerUrl, _settings.Username);
        if (string.IsNullOrWhiteSpace(_savedPassword))
            throw new InvalidOperationException("Tern 尚未保存密码。");
        var client = new TernBackendClient(_settings.ServerUrl, _settings.Username, _savedPassword);
        await client.LoginAsync().ConfigureAwait(true);
        return (client, _settings, _savedPassword);
    }

    private void Notify(string title, string message, ToolTipIcon icon)
    {
        _notifyIcon.BalloonTipTitle = title;
        _notifyIcon.BalloonTipText = message;
        _notifyIcon.BalloonTipIcon = icon;
        _notifyIcon.ShowBalloonTip(5000);
    }

    private void ExitApplication()
    {
        try
        {
            if (_sync.IsRunning)
            {
                var result = MessageBox.Show(
                    "退出 Tern 并停止本地同步吗？\n已下载的文件会保留在同步文件夹中。",
                    "Tern",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);
                if (result != DialogResult.Yes) return;
                _sync.StopAsync().GetAwaiter().GetResult();
            }
        }
        catch (Exception exception)
        {
            Log.Warn("退出时停止同步失败：" + exception.Message);
        }

        _stateTimer.Stop();
        _startupTimer.Stop();
        _updateTimer.Stop();
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _stateTimer.Dispose();
            _startupTimer.Dispose();
            _notifyIcon.Dispose();
            _sync.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        base.Dispose(disposing);
    }
}
