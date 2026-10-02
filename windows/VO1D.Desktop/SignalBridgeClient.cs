using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Text.Json;

namespace VO1D.Desktop;

internal sealed class SignalBridgeClient : IDisposable
{
    private readonly Process process;
    private readonly StreamWriter input;
    private readonly StreamReader output;
    private readonly SemaphoreSlim gate = new(1, 1);
    private long requestId;

    public SignalBridgeClient()
    {
        var runtime = EnsureRuntime();
        var node = Path.Combine(runtime, "node.exe");
        var bridge = Path.Combine(runtime, "bridge.js");
        if (!File.Exists(node) || !File.Exists(bridge))
            throw new InvalidOperationException("Signal runtime is incomplete.");

        process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = node,
                Arguments = Quote(bridge),
                WorkingDirectory = runtime,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardInputEncoding = Encoding.UTF8,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            },
            EnableRaisingEvents = true
        };

        if (!process.Start())
            throw new InvalidOperationException("Could not start Signal runtime.");

        input = process.StandardInput;
        output = process.StandardOutput;
        _ = Task.Run(async () =>
        {
            try
            {
                while (!process.HasExited)
                {
                    var line = await process.StandardError.ReadLineAsync();
                    if (line == null) break;
                }
            }
            catch { }
        });
    }

    private static string Quote(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";

    private static string EnsureRuntime()
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "VO1D", "signal-runtime", "0.70.0");
        var marker = Path.Combine(root, ".ready");

        if (File.Exists(marker) && File.Exists(Path.Combine(root, "node.exe")) && File.Exists(Path.Combine(root, "bridge.js")))
            return root;

        Directory.CreateDirectory(root);
        foreach (var entry in Directory.EnumerateFileSystemEntries(root))
        {
            try
            {
                if (Directory.Exists(entry)) Directory.Delete(entry, true);
                else File.Delete(entry);
            }
            catch { }
        }

        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("VO1D.SignalBridge.zip")
            ?? throw new InvalidOperationException("Signal runtime was not embedded in this build.");
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read);
        foreach (var entry in archive.Entries)
        {
            var destination = Path.GetFullPath(Path.Combine(root, entry.FullName));
            if (!destination.StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Invalid Signal runtime archive.");

            if (string.IsNullOrEmpty(entry.Name))
            {
                Directory.CreateDirectory(destination);
                continue;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            entry.ExtractToFile(destination, true);
        }

        File.WriteAllText(marker, "0.70.0", Encoding.UTF8);
        return root;
    }

    private async Task<JsonElement> CallAsync(object payload)
    {
        await gate.WaitAsync();
        try
        {
            if (process.HasExited)
                throw new InvalidOperationException("Signal runtime exited unexpectedly.");

            var id = Interlocked.Increment(ref requestId).ToString();
            var envelope = new Dictionary<string, object?>
            {
                ["id"] = id
            };

            foreach (var p in payload.GetType().GetProperties())
                envelope[p.Name] = p.GetValue(payload);

            await input.WriteLineAsync(JsonSerializer.Serialize(envelope, AppJson.Options));
            await input.FlushAsync();

            var line = await output.ReadLineAsync();
            if (line == null) throw new InvalidOperationException("Signal runtime returned no response.");

            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("ok", out var ok) || !ok.GetBoolean())
            {
                var error = root.TryGetProperty("error", out var e) ? e.GetString() : "Signal runtime failure";
                throw new InvalidOperationException(error ?? "Signal runtime failure");
            }

            return root.GetProperty("result").Clone();
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<string> CreateSnapshotAsync()
    {
        var result = await CallAsync(new { op = "create" });
        return result.GetProperty("snapshot").GetRawText();
    }

    public async Task<SignalPublicationResult> PublicationAsync(string snapshotJson, string owner, int count)
    {
        using var snapshot = JsonDocument.Parse(snapshotJson);
        var result = await CallAsync(new
        {
            op = "publication",
            snapshot = snapshot.RootElement.Clone(),
            owner,
            count
        });

        return new SignalPublicationResult
        {
            SnapshotJson = result.GetProperty("snapshot").GetRawText(),
            Bundles = JsonSerializer.Deserialize<List<SignalBundleDto>>(
                result.GetProperty("bundles").GetRawText(), AppJson.Options) ?? new()
        };
    }

    public async Task<SignalSessionResult> HasSessionAsync(string snapshotJson, string targetId)
    {
        using var snapshot = JsonDocument.Parse(snapshotJson);
        var result = await CallAsync(new
        {
            op = "hasSession",
            snapshot = snapshot.RootElement.Clone(),
            targetId
        });

        return new SignalSessionResult
        {
            SnapshotJson = result.GetProperty("snapshot").GetRawText(),
            HasSession = result.GetProperty("hasSession").GetBoolean()
        };
    }

    public async Task<SignalEncryptResult> EncryptAsync(
        string snapshotJson,
        string targetId,
        byte[] clear,
        SignalBundleDto? bundle)
    {
        using var snapshot = JsonDocument.Parse(snapshotJson);
        var result = await CallAsync(new
        {
            op = "encrypt",
            snapshot = snapshot.RootElement.Clone(),
            targetId,
            clear = Convert.ToBase64String(clear),
            bundle
        });

        var packet = JsonSerializer.Deserialize<SignalPacketDto>(
            result.GetProperty("packet").GetRawText(), AppJson.Options)
            ?? throw new InvalidDataException("Signal runtime returned an invalid packet.");

        return new SignalEncryptResult
        {
            SnapshotJson = result.GetProperty("snapshot").GetRawText(),
            Packet = packet
        };
    }

    public async Task<SignalDecryptResult> DecryptAsync(
        string snapshotJson,
        string senderId,
        SignalPacketDto packet)
    {
        using var snapshot = JsonDocument.Parse(snapshotJson);
        var result = await CallAsync(new
        {
            op = "decrypt",
            snapshot = snapshot.RootElement.Clone(),
            senderId,
            packet
        });

        return new SignalDecryptResult
        {
            SnapshotJson = result.GetProperty("snapshot").GetRawText(),
            Clear = Convert.FromBase64String(result.GetProperty("clear").GetString() ?? "")
        };
    }

    public void Dispose()
    {
        try { input.Close(); } catch { }
        try
        {
            if (!process.HasExited) process.Kill(true);
        }
        catch { }
        try { process.Dispose(); } catch { }
        gate.Dispose();
    }
}

internal sealed class SignalPublicationResult
{
    public string SnapshotJson { get; set; } = "";
    public List<SignalBundleDto> Bundles { get; set; } = new();
}

internal sealed class SignalSessionResult
{
    public string SnapshotJson { get; set; } = "";
    public bool HasSession { get; set; }
}

internal sealed class SignalEncryptResult
{
    public string SnapshotJson { get; set; } = "";
    public SignalPacketDto Packet { get; set; } = new();
}

internal sealed class SignalDecryptResult
{
    public string SnapshotJson { get; set; } = "";
    public byte[] Clear { get; set; } = Array.Empty<byte>();
}
