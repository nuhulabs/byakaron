using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
using Byakaron.Interop;
using Byakaron.Settings;
using Microsoft.UI.Dispatching;

namespace Byakaron.Updates;

public enum UpdateState
{
    Idle,
    Checking,
    UpToDate,
    Downloading,
    /// <summary>The installer is downloaded; restarting runs it.</summary>
    Ready,
    Failed,
}

/// <summary>
/// Byakaron updating itself from nuhulabs/Byakaron-Assets.
///
/// Which release to take is the shared core's call (src/Update.zig, through
/// <c>byakaron_update_pick</c>): the newest one the <c>update_channel</c>
/// setting takes that is newer than this build. This class does the Windows
/// part: once a day while <c>auto_update</c> is on (and on Check now), fetch
/// GitHub's release list, download that release's Byakaron-Setup.exe, check
/// it against the SHA-256 GitHub keeps for it (and, when this app is signed,
/// that the installer has the same signer); "Restart to update" runs it
/// silently (it closes and relaunches Byakaron, and keeps the tasks chosen at
/// install, the keyboard among them).
///
/// A local build (<c>byakaron_update_build_channel() &lt; 0</c>) only checks
/// when asked. One request to github.com per check; nothing about the user is sent.
/// </summary>
public sealed class Updater
{
    public static Updater Shared { get; } = new();

    public const string Asset = "Byakaron-Setup.exe";
    private static readonly TimeSpan Every = TimeSpan.FromDays(1);

    private readonly HttpClient _http;
    private DispatcherQueue? _dispatcher;
    private Timer? _timer;
    private string? _installer;
    private string? _readyVersion;
    private string? _error;
    private int _busy;

    /// <summary>Raised on the UI thread whenever <see cref="State"/> changes.</summary>
    public event Action? StateChanged;

    public UpdateState State { get; private set; } = UpdateState.Idle;

    /// <summary>"27.0.0-beta.3"</summary>
    public string CurrentVersion { get; }

    /// <summary>A release build, not a local one.</summary>
    public bool IsRelease { get; }

    private Updater()
    {
        try
        {
            CurrentVersion = ByakaronNative.Utf8String(ByakaronNative.Version()) ?? "?";
            IsRelease = ByakaronNative.UpdateBuildChannel() >= 0;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            CurrentVersion = "?";
        }
        _http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"Byakaron/{CurrentVersion} (Windows)");
    }

    public string StatusText => State switch
    {
        UpdateState.Checking => "Checking…",
        UpdateState.UpToDate => "This is the newest version on this channel.",
        UpdateState.Downloading => "Downloading the update…",
        UpdateState.Ready => $"Byakaron {_readyVersion} is ready. Restart Byakaron to finish.",
        UpdateState.Failed => _error ?? "The update failed.",
        _ => LastChecked is { } last
            ? $"Last checked {last.ToLocalTime():g}."
            : IsRelease ? "Not checked yet." : "A local build: checks only when asked.",
    };

    // ── Schedule ──

    /// <summary>Check if one is due, soon after launch and then every hour.</summary>
    public void Start(DispatcherQueue dispatcher)
    {
        if (_timer is not null) return;
        _dispatcher = dispatcher;
        _timer = new Timer(_ => _dispatcher.TryEnqueue(CheckIfDue), null, TimeSpan.FromSeconds(20), TimeSpan.FromHours(1));
    }

    private async void CheckIfDue()
    {
        // A test feed (BYAKARON_UPDATE_FEED) is checked at every launch.
        var testing = Environment.GetEnvironmentVariable("BYAKARON_UPDATE_FEED") is not null;
        var (auto, _) = ReadSettings();
        if (!(testing || IsRelease) || !auto) return;
        if (!testing && LastChecked is { } last && last <= DateTime.UtcNow && DateTime.UtcNow - last < Every) return;
        await CheckAsync();
    }

    /// <summary>The channel changed: what was found for the old one may not be right.</summary>
    public async void ChannelChanged()
    {
        if (State is UpdateState.Checking or UpdateState.Downloading) return;
        _installer = null;
        _readyVersion = null;
        SetState(UpdateState.Idle);
        await CheckAsync();
    }

    // ── Check and download ──

    public async Task CheckAsync()
    {
        if (State == UpdateState.Ready || Interlocked.Exchange(ref _busy, 1) == 1) return;
        try
        {
            SetState(UpdateState.Checking);
            var (_, channel) = ReadSettings();
            var feedUrl = ByakaronNative.Utf8String(ByakaronNative.UpdateFeedUrl())!;
            using var request = new HttpRequestMessage(HttpMethod.Get, feedUrl);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var response = await _http.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                throw new UpdateException($"github.com answered {(int)response.StatusCode}. Try again later.");
            }
            var feed = await response.Content.ReadAsStringAsync();
            LastChecked = DateTime.UtcNow;

            var release = Pick(feed, channel);
            if (release is null)
            {
                SetState(UpdateState.UpToDate);
                return;
            }
            SetState(UpdateState.Downloading);
            _installer = await DownloadAsync(release.Value);
            _readyVersion = release.Value.Version;
            SetState(UpdateState.Ready);
        }
        catch (Exception e)
        {
            Debug.WriteLine($"Byakaron: update failed: {e}");
            _error = e is UpdateException or HttpRequestException or TaskCanceledException
                ? e.Message
                : $"The update failed: {e.Message}";
            SetState(UpdateState.Failed);
        }
        finally
        {
            Interlocked.Exchange(ref _busy, 0);
        }
    }

    private readonly record struct Release(string Tag, string Version, string Url, string? Sha256);

    private static Release? Pick(string feed, int channel)
    {
        var r = new ByakaronNative.Release();
        var found = ByakaronNative.UpdatePick(feed, null, channel, Asset, ref r);
        try
        {
            return found switch
            {
                1 => new Release(
                    ByakaronNative.Utf8String(r.Tag)!,
                    ByakaronNative.Utf8String(r.Version)!,
                    ByakaronNative.Utf8String(r.Url)!,
                    ByakaronNative.Utf8String(r.Sha256)),
                0 => null,
                _ => throw new UpdateException("github.com sent something unexpected. Try again later."),
            };
        }
        finally
        {
            ByakaronNative.UpdateFree(ref r);
        }
    }

    private static string UpdatesDirectory => Path.Combine(ByakaronSettings.DataDirectory, "Updates");

    private async Task<string> DownloadAsync(Release release)
    {
        if (Directory.Exists(UpdatesDirectory)) Directory.Delete(UpdatesDirectory, recursive: true);
        var dir = Path.Combine(UpdatesDirectory, release.Tag);
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, Asset);

        using (var response = await _http.GetAsync(release.Url, HttpCompletionOption.ResponseHeadersRead))
        {
            if (!response.IsSuccessStatusCode)
            {
                throw new UpdateException($"The download failed ({(int)response.StatusCode}).");
            }
            await using var file = File.Create(path);
            await response.Content.CopyToAsync(file);
        }

        var expected = release.Sha256 ?? await SumFromSumsAsync(release);
        string actual;
        await using (var file = File.OpenRead(path))
        {
            actual = Convert.ToHexString(await SHA256.HashDataAsync(file)).ToLowerInvariant();
        }
        if (actual != expected.ToLowerInvariant())
        {
            File.Delete(path);
            throw new UpdateException("The download does not match its checksum.");
        }
        CheckSigner(path);
        return path;
    }

    /// <summary>The release's SHA256SUMS line for the installer.</summary>
    private async Task<string> SumFromSumsAsync(Release release)
    {
        var url = release.Url[..(release.Url.LastIndexOf('/') + 1)] + "SHA256SUMS";
        var sums = await _http.GetStringAsync(url);
        foreach (var line in sums.Split('\n'))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 2 && parts[1].TrimStart('*') == Asset) return parts[0];
        }
        throw new UpdateException($"The release has no checksum for {Asset}.");
    }

    /// <summary>When this app is Authenticode-signed, the installer must be signed by the same subject.</summary>
    private static void CheckSigner(string installer)
    {
        string? mine;
        try
        {
            mine = X509Certificate.CreateFromSignedFile(Environment.ProcessPath!).Subject;
        }
        catch (CryptographicException)
        {
            return; // An unsigned (local) build takes the checksum's word.
        }
        try
        {
            var theirs = X509Certificate.CreateFromSignedFile(installer).Subject;
            if (theirs == mine) return;
        }
        catch (CryptographicException)
        {
        }
        File.Delete(installer);
        throw new UpdateException("The installer is not signed by Byakaron's developer.");
    }

    // ── Install ──

    /// <summary>
    /// Run the installer silently and quit; it relaunches Byakaron when done
    /// (/RELAUNCH=1, see apps/windows/installer/Byakaron.iss). Windows asks to
    /// allow the installer, as at the first install.
    /// </summary>
    public void RestartAndInstall()
    {
        if (State != UpdateState.Ready || _installer is null || !File.Exists(_installer)) return;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = _installer,
                Arguments = "/SILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1",
                UseShellExecute = true,
            });
        }
        catch (Exception e)
        {
            // The UAC prompt was declined: stay, still ready.
            _error = e.Message;
            return;
        }
        Microsoft.UI.Xaml.Application.Current.Exit();
    }

    // ── Helpers ──

    private static DateTime? LastChecked
    {
        get
        {
            try
            {
                var path = Path.Combine(ByakaronSettings.DataDirectory, "last-update-check");
                return File.Exists(path) ? File.GetLastWriteTimeUtc(path) : null;
            }
            catch (IOException)
            {
                return null;
            }
        }
        set
        {
            try
            {
                Directory.CreateDirectory(ByakaronSettings.DataDirectory);
                var path = Path.Combine(ByakaronSettings.DataDirectory, "last-update-check");
                File.WriteAllText(path, string.Empty);
                File.SetLastWriteTimeUtc(path, value ?? DateTime.UtcNow);
            }
            catch (IOException)
            {
            }
        }
    }

    /// <summary><c>auto_update</c> and <c>update_channel</c> from the shared settings.</summary>
    private (bool Auto, int Channel) ReadSettings()
    {
        var fallback = 0;
        try { fallback = Math.Max(0, ByakaronNative.UpdateBuildChannel()); } catch (DllNotFoundException) { }
        using var store = ByakaronSettings.Open();
        if (store is null) return (true, fallback);
        return ((store.Get("auto_update") ?? 1) != 0, store.Get("update_channel") ?? fallback);
    }

    private void SetState(UpdateState state)
    {
        State = state;
        if (_dispatcher is null || _dispatcher.HasThreadAccess)
        {
            StateChanged?.Invoke();
        }
        else
        {
            _dispatcher.TryEnqueue(() => StateChanged?.Invoke());
        }
    }
}

public sealed class UpdateException(string message) : Exception(message);
