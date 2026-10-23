// Headless harness over the same C# bindings as the WinUI app. Used by CI and
// by Phase 3's cross-platform VTF round-trip. Secrets come from environment
// variables, never from argv (argv is visible to other processes).
//
//   STRONGROOM_PASSWORD     master password (vault + VTF password slot)
//   STRONGROOM_SECRET_KEY   Secret Key for an existing vault / VTF file
//   STRONGROOM_ITEM_PASSWORD optional password for `add`
//
// Exit codes: 0 ok, 1 failure, 2 usage, 3 the core reported Unsupported
// (FFI bodies not implemented yet).

using System.Text;
using Strongroom.Core.Security;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.Cli;

internal static class Program
{
    private const int ExitOk = 0, ExitFail = 1, ExitUsage = 2, ExitUnsupported = 3;

    // All core calls run on a large-stack thread (see CoreThread).
    private static int Main(string[] argv) => CoreThread.Run(() => Execute(argv));

    private static int Execute(string[] argv)
    {
        Console.OutputEncoding = Encoding.UTF8;
        if (argv.Length == 0)
            return Usage();
        try
        {
            var args = Args.Parse(argv.Skip(1));
            return argv[0] switch
            {
                "create" => Create(args),
                "add" => Add(args),
                "list" => List(args),
                "export" => Export(args),
                "import" => Import(args),
                "inspect" => Inspect(args),
                "roundtrip" => RoundTrip(args),
                "probe" => Probe(),
                _ => Usage(),
            };
        }
        catch (StrongroomException.Unsupported e)
        {
            Console.Error.WriteLine($"CORE UNSUPPORTED: {e.@reason}");
            return ExitUnsupported;
        }
        catch (StrongroomException e)
        {
            Console.Error.WriteLine($"ERROR: {CoreErrors.Describe(e)}");
            return ExitFail;
        }
        catch (UsageException e)
        {
            Console.Error.WriteLine($"usage error: {e.Message}");
            return ExitUsage;
        }
    }

    private static int Usage()
    {
        Console.Error.WriteLine("""
            strongroom-cli <command> [options]
              create    --vault PATH [--secret-key-out FILE]
              add       --vault PATH --title T [--username U] [--url U] [--totp SECRET] [--notes N]
              list      --vault PATH
              export    --vault PATH --out FILE.vtf
              import    --in FILE.vtf [--vault PATH]     prints imported item titles
              inspect   --in FILE.vtf
              roundtrip --dir DIR                        create, add, export, import into a second vault
              probe                                      FFI load + TPM / CNG key-agreement availability
            Secrets: STRONGROOM_PASSWORD, STRONGROOM_SECRET_KEY, STRONGROOM_ITEM_PASSWORD (env).
            """);
        return ExitUsage;
    }

    private static string Password() => Env("STRONGROOM_PASSWORD");
    private static string SecretKey() => Env("STRONGROOM_SECRET_KEY");

    private static string Env(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : throw new UsageException($"{name} is not set");

    private static Vault Open(Args a) => Vault.UnlockWithPassword(a.Required("vault"), Password(), SecretKey(), Clock.Now());

    private static string NewSecretKey()
    {
        var key = StrongroomCore.GenerateSecretKey();
        if (string.IsNullOrEmpty(key))
            throw new StrongroomException.Unsupported("generate_secret_key returned an empty Secret Key");
        return key;
    }

    private static int Create(Args a)
    {
        var path = a.Required("vault");
        var secretKey = NewSecretKey();
        using var vault = Vault.Create(path, Password(), secretKey, Clock.Now());
        if (a.Optional("secret-key-out") is { } file)
        {
            File.WriteAllText(file, secretKey);
            Console.WriteLine($"created {path}; Secret Key written to {file}");
        }
        else
        {
            Console.WriteLine($"created {path}");
            Console.WriteLine($"SECRET KEY: {secretKey}");
        }
        Console.WriteLine("A lost master password or Secret Key means permanent, unrecoverable data loss.");
        return ExitOk;
    }

    private static ItemInput Login(string title, string? username, string? password, string? url, string? totp, string? notes) =>
        new(Kind: ItemKind.Login, Title: title, Username: username, Password: password,
            Urls: url is null ? Array.Empty<string>() : new[] { url }, Notes: notes, Totp: totp, Folder: null,
            Tags: Array.Empty<string>(), Fields: Array.Empty<CustomField>(), TravelSafe: false);

    private static int Add(Args a)
    {
        using var vault = Open(a);
        var id = vault.AddItem(Login(a.Required("title"), a.Optional("username"),
            Environment.GetEnvironmentVariable("STRONGROOM_ITEM_PASSWORD"), a.Optional("url"), a.Optional("totp"), a.Optional("notes")), Clock.Now());
        Console.WriteLine($"added {id}");
        return ExitOk;
    }

    private static int List(Args a)
    {
        using var vault = Open(a);
        PrintTitles(vault);
        return ExitOk;
    }

    private static void PrintTitles(Vault vault)
    {
        var items = vault.Search("", null, null).OrderBy(i => i.Title, StringComparer.Ordinal).ToArray();
        Console.WriteLine($"ITEMS: {items.Length}");
        foreach (var i in items)
            Console.WriteLine($"TITLE: {i.Title}");
    }

    private static int Export(Args a)
    {
        using var vault = Open(a);
        var bytes = vault.ExportVtf(Password(), SecretKey(), Array.Empty<byte[]>(), Clock.Now());
        File.WriteAllBytes(a.Required("out"), bytes);
        Console.WriteLine($"exported {bytes.Length} bytes to {a.Required("out")}");
        return ExitOk;
    }

    private static int Import(Args a)
    {
        var file = File.ReadAllBytes(a.Required("in"));
        string? tempDir = null;
        Vault vault;
        if (a.Optional("vault") is { } path)
        {
            vault = Open(a);
        }
        else
        {
            // Fresh throwaway vault with its own Secret Key; the file is opened
            // with the exporting vault's password + Secret Key (password slot).
            tempDir = Directory.CreateTempSubdirectory("strongroom-import-").FullName;
            vault = Vault.Create(Path.Combine(tempDir, "import.srdb"), Password(), NewSecretKey(), Clock.Now());
        }
        try
        {
            var s = vault.ImportVtf(file, Password(), SecretKey(), Clock.Now());
            Console.WriteLine($"IMPORTED: added={s.Added} updated={s.Updated} unchanged={s.Unchanged} conflicts={s.Conflicts}");
            PrintTitles(vault);
        }
        finally
        {
            vault.Dispose();
            if (tempDir is not null)
                Directory.Delete(tempDir, recursive: true);
        }
        return ExitOk;
    }

    private static int Inspect(Args a)
    {
        var info = StrongroomCore.VtfInspect(File.ReadAllBytes(a.Required("in")));
        Console.WriteLine($"VTF version={info.Version} password_slots={info.PasswordSlots} device_slots={info.DeviceSlots} chunks={info.ChunkCount}");
        return ExitOk;
    }

    private static int RoundTrip(Args a)
    {
        var dir = Directory.CreateDirectory(a.Required("dir")).FullName;
        var password = Password();
        var now = Clock.Now();
        string[] titles = { "Windows: Example Login", "Windows: Bank", "Windows: Ünïcödé ✓" };

        var secretA = NewSecretKey();
        File.WriteAllText(Path.Combine(dir, "source.secret-key.txt"), secretA);
        using (var source = Vault.Create(Path.Combine(dir, "source.srdb"), password, secretA, now))
        {
            source.AddItem(Login(titles[0], "alice@example.com", "correct horse battery staple", "https://example.com", "JBSWY3DPEHPK3PXP", null), now);
            source.AddItem(Login(titles[1], "alice", "hunter2-but-longer", "https://bank.example", null, "note"), now);
            source.AddItem(Login(titles[2], null, "pässwörd", null, null, null), now);
            Console.WriteLine("source vault: 3 items added");
            var vtf = source.ExportVtf(password, secretA, Array.Empty<byte[]>(), now);
            var vtfPath = Path.Combine(dir, "windows-roundtrip.vtf");
            File.WriteAllBytes(vtfPath, vtf);
            Console.WriteLine($"EXPORTED: {vtfPath} ({vtf.Length} bytes)");
            var info = StrongroomCore.VtfInspect(vtf);
            Console.WriteLine($"VTF version={info.Version} password_slots={info.PasswordSlots} device_slots={info.DeviceSlots} chunks={info.ChunkCount}");
        }

        var vtfBytes = File.ReadAllBytes(Path.Combine(dir, "windows-roundtrip.vtf"));
        using var target = Vault.Create(Path.Combine(dir, "target.srdb"), password, NewSecretKey(), now + 1);
        var summary = target.ImportVtf(vtfBytes, password, secretA, now + 1);
        Console.WriteLine($"IMPORTED: added={summary.Added} updated={summary.Updated} unchanged={summary.Unchanged} conflicts={summary.Conflicts}");
        PrintTitles(target);

        var got = target.Search("", null, null).Select(i => i.Title).OrderBy(t => t, StringComparer.Ordinal).ToArray();
        var want = titles.OrderBy(t => t, StringComparer.Ordinal).ToArray();
        if (!got.SequenceEqual(want))
        {
            Console.Error.WriteLine("ROUNDTRIP FAILED: imported titles differ from exported titles");
            return ExitFail;
        }

        // Wrong Secret Key must be rejected with UnlockFailed (no detail).
        try
        {
            target.ImportVtf(vtfBytes, password, NewSecretKey(), now + 2);
            Console.Error.WriteLine("ROUNDTRIP FAILED: import with a wrong Secret Key succeeded");
            return ExitFail;
        }
        catch (StrongroomException.UnlockFailed)
        {
            Console.WriteLine("wrong Secret Key correctly rejected (UnlockFailed)");
        }
        Console.WriteLine("ROUNDTRIP OK");
        return ExitOk;
    }

    private static int Probe()
    {
        Console.WriteLine($"OS: {Environment.OSVersion.VersionString} ({System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture})");
        try
        {
            var sk = StrongroomCore.GenerateSecretKey();
            Console.WriteLine($"FFI: strongroom_ffi loaded; generate_secret_key -> {(sk.Length == 0 ? "empty (core stub)" : $"{sk.Length} chars")}");
            var strength = StrongroomCore.EstimateStrength("correct horse battery staple");
            Console.WriteLine($"FFI: estimate_strength -> score={strength.Score} entropy={strength.EntropyBits:F1}");
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or TypeInitializationException or UniffiException)
        {
            Console.WriteLine($"FFI: FAILED to load/call strongroom_ffi: {e.GetType().Name}: {e.Message}");
            return ExitFail;
        }

        foreach (var provider in new[] { KeyProviders.PlatformTpm, KeyProviders.Software })
        {
            var r = DeviceKeyProbe.Run(provider);
            Console.WriteLine($"CNG [{r.Provider}]: provider={(r.ProviderOpened ? "yes" : "no")} p256-key={(r.KeyCreated ? "yes" : "no")} " +
                              $"ecdh-matches-dotnet={(r.AgreementMatches ? "yes" : "no")} :: {r.Detail}");
        }
        var tpm = DeviceKeyProbe.Run(KeyProviders.PlatformTpm);
        Console.WriteLine(tpm.AgreementMatches
            ? "DEVICE UNLOCK: available (TPM P-256 key agreement works)"
            : "DEVICE UNLOCK: unavailable on this machine -> Windows Hello unlock and device-bound export are disabled; password unlock only");
        return ExitOk;
    }
}

internal sealed class UsageException(string message) : Exception(message);

internal sealed class Args
{
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);

    public static Args Parse(IEnumerable<string> argv)
    {
        var a = new Args();
        using var e = argv.GetEnumerator();
        while (e.MoveNext())
        {
            var key = e.Current;
            if (!key.StartsWith("--", StringComparison.Ordinal))
                throw new UsageException($"unexpected argument '{key}'");
            if (!e.MoveNext())
                throw new UsageException($"missing value for {key}");
            a._values[key[2..]] = e.Current;
        }
        return a;
    }

    public string Required(string name) =>
        _values.TryGetValue(name, out var v) ? v : throw new UsageException($"--{name} is required");

    public string? Optional(string name) => _values.TryGetValue(name, out var v) ? v : null;
}
