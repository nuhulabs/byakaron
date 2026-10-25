using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Windows.System;

namespace Byakaron.Keyboard;

/// <summary>
/// Installs the Byakaron TSF Text Input Processor (TIP) so it appears in
/// Win+Space / taskbar Input Indicator under Bangla (Bangladesh), mirroring
/// macOS <c>KeyboardInstaller</c> for Input Methods.
/// </summary>
public static class KeyboardInstaller
{
    public const string DisplayName = "Byakaron";
    public const string LanguageTag = "bn-BD";

    /// <summary>Per-user install directory for the TIP + Zig FFI DLL.</summary>
    public static string InstallDirectory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Byakaron",
            "IME");

    public static string TipDllPath => Path.Combine(InstallDirectory, "ByakaronIME.dll");
    public static string FfiDllPath => Path.Combine(InstallDirectory, "byakaron.dll");

    public static bool IsTipPresentOnDisk() => File.Exists(TipDllPath) && File.Exists(FfiDllPath);

    /// <summary>
    /// Copy staged TIP payload next to the app into LocalAppData, then elevate
    /// <c>regsvr32</c> so TSF can register the profile (HKCR/HKLM).
    /// </summary>
    public static async Task<KeyboardInstallResult> EnsureInstalledAsync()
    {
        try
        {
            var staged = FindStagedPayload();
            if (staged is null)
            {
                return KeyboardInstallResult.Failed(
                    "IME payload not found. Build the app with zig build run-win");
            }

            Directory.CreateDirectory(InstallDirectory);
            File.Copy(Path.Combine(staged, "ByakaronIME.dll"), TipDllPath, overwrite: true);
            File.Copy(Path.Combine(staged, "byakaron.dll"), FfiDllPath, overwrite: true);

            var ok = await RunElevatedAsync("regsvr32.exe", $"/s \"{TipDllPath}\"");
            if (!ok)
            {
                return KeyboardInstallResult.Failed(
                    "Registration was cancelled or failed. Administrator approval is required to register the keyboard.");
            }

            return KeyboardInstallResult.Ok(
                "Byakaron keyboard installed. Switch with Win+Space (look for BN / Byakaron).");
        }
        catch (Exception ex)
        {
            return KeyboardInstallResult.Failed(ex.Message);
        }
    }

    public static async Task<KeyboardInstallResult> UninstallAsync()
    {
        try
        {
            if (File.Exists(TipDllPath))
            {
                await RunElevatedAsync("regsvr32.exe", $"/u /s \"{TipDllPath}\"");
            }

            if (Directory.Exists(InstallDirectory))
            {
                try { Directory.Delete(InstallDirectory, recursive: true); }
                catch { /* files may be locked until logoff */ }
            }

            return KeyboardInstallResult.Ok("Byakaron keyboard unregistered.");
        }
        catch (Exception ex)
        {
            return KeyboardInstallResult.Failed(ex.Message);
        }
    }

    public static async Task OpenLanguageSettingsAsync()
    {
        // Windows 11 Language & region → keyboards / input methods.
        await Launcher.LaunchUriAsync(new Uri("ms-settings:regionlanguage"));
    }

    private static string? FindStagedPayload()
    {
        var baseDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            Path.Combine(baseDir, "ime"),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "..", "Keyboard", "stage")),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "Keyboard", "stage")),
        };

        foreach (var dir in candidates)
        {
            if (File.Exists(Path.Combine(dir, "ByakaronIME.dll")) &&
                File.Exists(Path.Combine(dir, "byakaron.dll")))
            {
                return dir;
            }
        }

        return null;
    }

    private static Task<bool> RunElevatedAsync(string fileName, string arguments)
    {
        var tcs = new TaskCompletionSource<bool>();
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            var proc = Process.Start(psi);
            if (proc is null)
            {
                tcs.SetResult(false);
                return tcs.Task;
            }

            proc.EnableRaisingEvents = true;
            proc.Exited += (_, _) => tcs.TrySetResult(proc.ExitCode == 0);
            if (proc.HasExited)
            {
                tcs.TrySetResult(proc.ExitCode == 0);
            }
        }
        catch (Exception)
        {
            // User declined UAC.
            tcs.SetResult(false);
        }

        return tcs.Task;
    }
}

public sealed class KeyboardInstallResult
{
    public bool Success { get; init; }
    public string Message { get; init; } = string.Empty;

    public static KeyboardInstallResult Ok(string message) => new() { Success = true, Message = message };
    public static KeyboardInstallResult Failed(string message) => new() { Success = false, Message = message };
}
