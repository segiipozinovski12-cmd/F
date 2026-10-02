using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using NSec.Cryptography;

namespace VO1D.Desktop;

internal static class AppJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
}

internal sealed class ContactCard
{
    public string Id { get; set; } = "";
    public string SigningKey { get; set; } = "";
    public string AgreementKey { get; set; } = "";
    public string Binding { get; set; } = "";
}

internal sealed class Envelope
{
    public string Id { get; set; } = "";
    public string Sender { get; set; } = "";
    public string Recipient { get; set; } = "";
    public string EphemeralKey { get; set; } = "";
    public string Salt { get; set; } = "";
    public int ExpiresAt { get; set; }
    public string Ciphertext { get; set; } = "";
    public string Signature { get; set; } = "";

    [JsonIgnore]
    public byte[] Header => Encoding.UTF8.GetBytes(
        $"VO1D-ENVELOPE-1\n{Id}\n{Sender}\n{Recipient}\n{EphemeralKey}\n{Salt}\n{ExpiresAt}");
}

internal sealed class LocalIdentity
{
    public byte[] Signing { get; set; } = Array.Empty<byte>();
    public byte[] Agreement { get; set; } = Array.Empty<byte>();
    public byte[] Storage { get; set; } = Array.Empty<byte>();
}

internal sealed class ContactState
{
    public string Name { get; set; } = "";
    public ContactCard Card { get; set; } = new();
    public bool Verified { get; set; }
    public bool Blocked { get; set; }
    public bool Favorite { get; set; }
    public string Note { get; set; } = "";
    public string Alias { get; set; } = "";
}

internal sealed class AttachmentState
{
    public string Name { get; set; } = "";
    public string Mime { get; set; } = "application/octet-stream";
    public byte[] Data { get; set; } = Array.Empty<byte>();
    public int? ViewSeconds { get; set; }
}

internal sealed class LocalMessage
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    // Kept for migration from the first Windows beta.
    public string PeerId { get; set; } = "";
    public string RoomId { get; set; } = "";
    public string SenderId { get; set; } = "";
    public bool Mine { get; set; }
    public string Text { get; set; } = "";
    public long CreatedAt { get; set; }
    public long? ExpiresAt { get; set; }
    public string? ReplyTo { get; set; }
    public AttachmentState? Attachment { get; set; }
    public string State { get; set; } = "sent";
    public bool Edited { get; set; }
    public Dictionary<string, string> Reactions { get; set; } = new();
    public bool Bookmarked { get; set; }
    public long? ScheduledAt { get; set; }
    public bool Silent { get; set; }
    public List<string> EditHistory { get; set; } = new();
}

internal sealed class RoomState
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public List<string> MemberIds { get; set; } = new();
    public string Creator { get; set; } = "";
    public bool IsGroup { get; set; }
    public bool IsChannel { get; set; }
    public long CreatedAt { get; set; }
    public bool Pinned { get; set; }
    public bool Archived { get; set; }
    public bool Muted { get; set; }
    public int Unread { get; set; }
    public string Draft { get; set; } = "";
    public int DisappearingSeconds { get; set; }
    public bool OnlyAdminsCanPost { get; set; }
    public List<string> Admins { get; set; } = new();
    public List<string> PinnedMessageIds { get; set; } = new();
    public List<string> Topics { get; set; } = new();
    public string Note { get; set; } = "";
}

internal sealed class ChatFolderState
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public List<string> RoomIds { get; set; } = new();
}

internal sealed class DesktopPreferences
{
    public bool CompactRows { get; set; }
    public bool ConfirmLinks { get; set; } = true;
    public bool CleanLinks { get; set; } = true;
    public bool HideMedia { get; set; }
    public bool LowData { get; set; }
    public bool QuietHours { get; set; }
    public bool ProtectCapture { get; set; } = true;
    public bool ReadReceipts { get; set; } = true;
    public int TextScale { get; set; } = 100;
    public int FileLimitMb { get; set; } = 25;
}

internal sealed class VaultState
{
    public string Nickname { get; set; } = "Ghost";
    public string? PublicCode { get; set; }
    public string? Username { get; set; }
    public List<ContactState> Contacts { get; set; } = new();
    public List<RoomState> Rooms { get; set; } = new();
    public List<LocalMessage> Messages { get; set; } = new();
    public HashSet<string> Processed { get; set; } = new();
    public HashSet<string> HiddenRooms { get; set; } = new();
    public List<ChatFolderState> Folders { get; set; } = new();
    public DesktopPreferences Preferences { get; set; } = new();
    public string? SignalSnapshotJson { get; set; }
}

internal sealed class SignalBundleDto
{
    public string Owner { get; set; } = "";
    public string IdentityKey { get; set; } = "";
    public string IdentityBinding { get; set; } = "";
    public uint RegistrationId { get; set; }
    public uint DeviceId { get; set; } = 1;
    public uint SignedPrekeyId { get; set; }
    public string SignedPrekey { get; set; } = "";
    public string SignedPrekeySignature { get; set; } = "";
    public uint PrekeyId { get; set; }
    public string Prekey { get; set; } = "";
    public uint KyberPrekeyId { get; set; }
    public string KyberPrekey { get; set; } = "";
    public string KyberPrekeySignature { get; set; } = "";
    public int ExpiresAt { get; set; }
    public string Signature { get; set; } = "";
}

internal sealed class SignalPublicationDto
{
    public List<SignalBundleDto> Bundles { get; set; } = new();
}

internal sealed class SignalPacketDto
{
    public int Version { get; set; } = 2;
    public string IdentityKey { get; set; } = "";
    public string IdentityBinding { get; set; } = "";
    public byte Type { get; set; }
    public byte[] Ciphertext { get; set; } = Array.Empty<byte>();
}

internal sealed class IdentityCrypto : IDisposable
{
    private static readonly SignatureAlgorithm Ed = SignatureAlgorithm.Ed25519;
    private static readonly KeyAgreementAlgorithm X = KeyAgreementAlgorithm.X25519;
    private static KeyCreationParameters Exportable() => new() { ExportPolicy = KeyExportPolicies.AllowPlaintextExport };

    private readonly Key signing;
    private readonly Key agreement;
    public LocalIdentity Raw { get; }

    public IdentityCrypto(LocalIdentity raw)
    {
        Raw = raw;
        signing = Key.Import(Ed, raw.Signing, KeyBlobFormat.RawPrivateKey, Exportable());
        agreement = Key.Import(X, raw.Agreement, KeyBlobFormat.RawPrivateKey, Exportable());
    }

    public static LocalIdentity Create()
    {
        using var sign = new Key(Ed, Exportable());
        using var agree = new Key(X, Exportable());
        return new LocalIdentity
        {
            Signing = sign.Export(KeyBlobFormat.RawPrivateKey),
            Agreement = agree.Export(KeyBlobFormat.RawPrivateKey),
            Storage = RandomNumberGenerator.GetBytes(32)
        };
    }

    public ContactCard Card
    {
        get
        {
            var signPub = signing.PublicKey.Export(KeyBlobFormat.RawPublicKey);
            var agreePub = agreement.PublicKey.Export(KeyBlobFormat.RawPublicKey);
            var card = new ContactCard
            {
                Id = Convert.ToHexString(SHA256.HashData(signPub)).ToLowerInvariant(),
                SigningKey = Convert.ToBase64String(signPub),
                AgreementKey = Convert.ToBase64String(agreePub)
            };
            card.Binding = Convert.ToBase64String(Ed.Sign(signing, CardBytes(card)));
            return card;
        }
    }

    public byte[] Sign(ReadOnlySpan<byte> data) => Ed.Sign(signing, data);

    public static byte[] SignalBindingBytes(string identityKey, string owner) =>
        Encoding.UTF8.GetBytes($"VO1D-SIGNAL-IDENTITY-2\n{owner}\n{identityKey}");

    public static byte[] BundleBytes(SignalBundleDto bundle) =>
        Encoding.UTF8.GetBytes(
            $"VO1D-PREKEY-2\n{bundle.Owner}\n{bundle.IdentityKey}\n{bundle.IdentityBinding}\n{bundle.RegistrationId}\n{bundle.DeviceId}\n{bundle.SignedPrekeyId}\n{bundle.SignedPrekey}\n{bundle.SignedPrekeySignature}\n{bundle.PrekeyId}\n{bundle.Prekey}\n{bundle.KyberPrekeyId}\n{bundle.KyberPrekey}\n{bundle.KyberPrekeySignature}\n{bundle.ExpiresAt}");

    public void CompleteSignalBundle(SignalBundleDto bundle)
    {
        bundle.IdentityBinding = Convert.ToBase64String(Sign(SignalBindingBytes(bundle.IdentityKey, Card.Id)));
        bundle.Signature = Convert.ToBase64String(Sign(BundleBytes(bundle)));
    }

    public void CompleteSignalPacket(SignalPacketDto packet)
    {
        packet.IdentityBinding = Convert.ToBase64String(Sign(SignalBindingBytes(packet.IdentityKey, Card.Id)));
    }

    private static bool VerifyOuter(ContactCard card, ReadOnlySpan<byte> data, byte[] signature)
    {
        var pub = PublicKey.Import(Ed, Convert.FromBase64String(card.SigningKey), KeyBlobFormat.RawPublicKey);
        return Ed.Verify(pub, data, signature);
    }

    public static void ValidateSignalBinding(string identityKey, string binding, ContactCard card)
    {
        Validate(card);
        var key = Convert.FromBase64String(identityKey);
        var sig = Convert.FromBase64String(binding);
        if (key.Length != 33 || sig.Length != 64 ||
            !VerifyOuter(card, SignalBindingBytes(identityKey, card.Id), sig))
            throw new InvalidDataException("Неверная привязка ключа Signal.");
    }

    public static void ValidateSignalBundle(SignalBundleDto bundle, ContactCard card)
    {
        ValidateSignalBinding(bundle.IdentityKey, bundle.IdentityBinding, card);
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (!bundle.Owner.Equals(card.Id, StringComparison.Ordinal) ||
            bundle.DeviceId != 1 ||
            bundle.ExpiresAt <= now ||
            bundle.ExpiresAt > now + 8 * 86400)
            throw new InvalidDataException("Неверный или истёкший набор ключей Signal.");

        var signature = Convert.FromBase64String(bundle.Signature);
        if (signature.Length != 64 || !VerifyOuter(card, BundleBytes(bundle), signature))
            throw new InvalidDataException("Подмена набора ключей Signal.");
    }

    public static void ValidateSignalPacket(SignalPacketDto packet, ContactCard sender)
    {
        if (packet.Version != 2 || packet.Ciphertext.Length > 7 * 1024 * 1024)
            throw new InvalidDataException("Неподдерживаемый пакет Signal.");
        ValidateSignalBinding(packet.IdentityKey, packet.IdentityBinding, sender);
    }

    public static byte[] CardBytes(ContactCard card) =>
        Encoding.UTF8.GetBytes($"VO1D-CARD-1\n{card.Id}\n{card.SigningKey}\n{card.AgreementKey}");

    public static void Validate(ContactCard card)
    {
        var sign = Convert.FromBase64String(card.SigningKey);
        var agree = Convert.FromBase64String(card.AgreementKey);
        var binding = Convert.FromBase64String(card.Binding);
        if (sign.Length != 32 || agree.Length != 32 || binding.Length != 64)
            throw new InvalidDataException("Повреждённая карточка контакта");
        if (!Convert.ToHexString(SHA256.HashData(sign)).ToLowerInvariant().Equals(card.Id, StringComparison.Ordinal))
            throw new InvalidDataException("Отпечаток контакта не совпадает");
        var pub = PublicKey.Import(Ed, sign, KeyBlobFormat.RawPublicKey);
        if (!Ed.Verify(pub, CardBytes(card), binding))
            throw new InvalidDataException("Подпись контакта не прошла проверку");
    }

    public Envelope Seal(byte[] clear, ContactCard recipient)
    {
        Validate(recipient);
        var own = Card;
        using var ephemeral = new Key(X, Exportable());
        var remote = PublicKey.Import(X, Convert.FromBase64String(recipient.AgreementKey), KeyBlobFormat.RawPublicKey);
        using var shared = X.Agree(ephemeral, remote) ?? throw new CryptographicException("X25519 key agreement failed");

        var env = new Envelope
        {
            Id = Guid.NewGuid().ToString(),
            Sender = own.Id,
            Recipient = recipient.Id,
            EphemeralKey = Convert.ToBase64String(ephemeral.PublicKey.Export(KeyBlobFormat.RawPublicKey)),
            Salt = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)),
            ExpiresAt = checked((int)DateTimeOffset.UtcNow.AddDays(7).ToUnixTimeSeconds())
        };

        var key = KeyDerivationAlgorithm.HkdfSha256.DeriveBytes(shared, Convert.FromBase64String(env.Salt), env.Header, 32);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[clear.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(key, 16))
            aes.Encrypt(nonce, clear, cipher, tag, env.Header);

        var combined = new byte[nonce.Length + cipher.Length + tag.Length];
        Buffer.BlockCopy(nonce, 0, combined, 0, nonce.Length);
        Buffer.BlockCopy(cipher, 0, combined, nonce.Length, cipher.Length);
        Buffer.BlockCopy(tag, 0, combined, nonce.Length + cipher.Length, tag.Length);
        env.Ciphertext = Convert.ToBase64String(combined);

        var signed = new byte[env.Header.Length + 1 + combined.Length];
        Buffer.BlockCopy(env.Header, 0, signed, 0, env.Header.Length);
        signed[env.Header.Length] = 10;
        Buffer.BlockCopy(combined, 0, signed, env.Header.Length + 1, combined.Length);
        env.Signature = Convert.ToBase64String(Sign(signed));
        CryptographicOperations.ZeroMemory(key);
        return env;
    }

    public byte[] Open(Envelope env, ContactCard sender)
    {
        Validate(sender);
        if (!env.Sender.Equals(sender.Id, StringComparison.Ordinal) ||
            !env.Recipient.Equals(Card.Id, StringComparison.Ordinal) ||
            env.ExpiresAt <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
            throw new InvalidDataException("Сообщение адресовано другому устройству или истекло");

        var combined = Convert.FromBase64String(env.Ciphertext);
        if (combined.Length < 28) throw new InvalidDataException("Повреждённый ciphertext");

        var signed = new byte[env.Header.Length + 1 + combined.Length];
        Buffer.BlockCopy(env.Header, 0, signed, 0, env.Header.Length);
        signed[env.Header.Length] = 10;
        Buffer.BlockCopy(combined, 0, signed, env.Header.Length + 1, combined.Length);

        var signPub = PublicKey.Import(Ed, Convert.FromBase64String(sender.SigningKey), KeyBlobFormat.RawPublicKey);
        if (!Ed.Verify(signPub, signed, Convert.FromBase64String(env.Signature)))
            throw new InvalidDataException("Подпись сообщения не прошла проверку");

        var eph = PublicKey.Import(X, Convert.FromBase64String(env.EphemeralKey), KeyBlobFormat.RawPublicKey);
        using var shared = X.Agree(agreement, eph) ?? throw new CryptographicException("X25519 key agreement failed");
        var key = KeyDerivationAlgorithm.HkdfSha256.DeriveBytes(shared, Convert.FromBase64String(env.Salt), env.Header, 32);

        var nonce = combined.AsSpan(0, 12).ToArray();
        var cipherLen = combined.Length - 28;
        var cipher = combined.AsSpan(12, cipherLen).ToArray();
        var tag = combined.AsSpan(12 + cipherLen, 16).ToArray();
        var clear = new byte[cipherLen];
        using (var aes = new AesGcm(key, 16))
            aes.Decrypt(nonce, cipher, tag, clear, env.Header);
        CryptographicOperations.ZeroMemory(key);
        return clear;
    }

    public void Dispose()
    {
        signing.Dispose();
        agreement.Dispose();
    }
}

internal sealed class LocalStore
{
    private readonly string identityPath;
    private readonly string vaultPath;

    public LocalStore()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VO1D");
        Directory.CreateDirectory(root);
        identityPath = Path.Combine(root, "identity.dpapi");
        vaultPath = Path.Combine(root, "vault.bin");
    }

    public LocalIdentity LoadOrCreateIdentity()
    {
        if (File.Exists(identityPath))
        {
            var clear = ProtectedData.Unprotect(File.ReadAllBytes(identityPath), null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<LocalIdentity>(clear, AppJson.Options)
                   ?? throw new InvalidDataException("Не удалось прочитать identity");
        }

        var identity = IdentityCrypto.Create();
        var json = JsonSerializer.SerializeToUtf8Bytes(identity, AppJson.Options);
        File.WriteAllBytes(identityPath, ProtectedData.Protect(json, null, DataProtectionScope.CurrentUser));
        return identity;
    }

    public VaultState LoadVault(byte[] key)
    {
        if (!File.Exists(vaultPath)) return new VaultState();
        var all = File.ReadAllBytes(vaultPath);
        if (all.Length < 28) return new VaultState();
        var nonce = all.AsSpan(0, 12).ToArray();
        var tag = all.AsSpan(all.Length - 16, 16).ToArray();
        var cipher = all.AsSpan(12, all.Length - 28).ToArray();
        var clear = new byte[cipher.Length];
        using (var aes = new AesGcm(key, 16))
            aes.Decrypt(nonce, cipher, tag, clear);
        return JsonSerializer.Deserialize<VaultState>(clear, AppJson.Options) ?? new VaultState();
    }

    public void SaveVault(VaultState state, byte[] key)
    {
        var clear = JsonSerializer.SerializeToUtf8Bytes(state, AppJson.Options);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[clear.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(key, 16))
            aes.Encrypt(nonce, clear, cipher, tag);
        var all = new byte[12 + cipher.Length + 16];
        Buffer.BlockCopy(nonce, 0, all, 0, 12);
        Buffer.BlockCopy(cipher, 0, all, 12, cipher.Length);
        Buffer.BlockCopy(tag, 0, all, 12 + cipher.Length, 16);
        File.WriteAllBytes(vaultPath, all);
        CryptographicOperations.ZeroMemory(clear);
    }
}

internal sealed class Vo1dApi : IDisposable
{
    public const string ProductionRelay = "https://f-production-bdfe.up.railway.app";
    private readonly HttpClient http = new() { BaseAddress = new Uri(ProductionRelay + "/"), Timeout = TimeSpan.FromSeconds(30) };
    private readonly IdentityCrypto identity;
    private string? token;

    public Vo1dApi(IdentityCrypto identity) => this.identity = identity;

    private async Task<T> SendAsync<T>(HttpMethod method, string path, object? body = null, bool retry = true)
    {
        using var req = new HttpRequestMessage(method, path);
        if (body != null)
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(body, AppJson.Options);
            req.Content = new ByteArrayContent(bytes);
            req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }
        if (token != null) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var res = await http.SendAsync(req);
        var data = await res.Content.ReadAsByteArrayAsync();

        if (res.StatusCode == System.Net.HttpStatusCode.Unauthorized && retry)
        {
            await AuthenticateAsync();
            return await SendAsync<T>(method, path, body, false);
        }

        if (!res.IsSuccessStatusCode)
        {
            string detail;
            try
            {
                using var doc = JsonDocument.Parse(data);
                detail = doc.RootElement.TryGetProperty("error", out var e) ? e.GetString() ?? "server error" : "server error";
            }
            catch { detail = Encoding.UTF8.GetString(data); }
            throw new InvalidOperationException($"{(int)res.StatusCode}: {detail}");
        }

        return JsonSerializer.Deserialize<T>(data, AppJson.Options)
               ?? throw new InvalidDataException("Пустой ответ сервера");
    }

    public async Task AuthenticateAsync()
    {
        token = null;
        await SendAsync<OkResponse>(HttpMethod.Post, "v1/register", identity.Card, false);
        var challenge = await SendAsync<ChallengeResponse>(HttpMethod.Post, "v1/challenge", new { id = identity.Card.Id }, false);
        var auth = Encoding.UTF8.GetBytes($"VO1D-AUTH-1\n{identity.Card.Id}\n{challenge.Nonce}");
        var session = await SendAsync<SessionResponse>(HttpMethod.Post, "v1/session",
            new { id = identity.Card.Id, nonce = challenge.Nonce, signature = Convert.ToBase64String(identity.Sign(auth)) }, false);
        token = session.Token;
    }

    public async Task<string> EnsureCodeAsync() =>
        (await SendAsync<CodeResponse>(HttpMethod.Post, "v1/code", new { })).Code;

    public async Task<string> RotateCodeAsync() =>
        (await SendAsync<CodeResponse>(HttpMethod.Post, "v1/code/rotate", new { })).Code;

    public Task<ContactCard> LookupCodeAsync(string code) =>
        SendAsync<ContactCard>(HttpMethod.Get, "v1/code/" + Uri.EscapeDataString(code.ToUpperInvariant()));

    public async Task<ContactCard> LookupUsernameAsync(string username) =>
        (await SendAsync<UsernameLookup>(HttpMethod.Get, "v1/username/" + Uri.EscapeDataString(username.Trim().TrimStart('@').ToLowerInvariant()))).Card;

    public Task<ContactCard> LookupIdAsync(string id) =>
        SendAsync<ContactCard>(HttpMethod.Get, "v1/identity/" + id.ToLowerInvariant());

    public Task<OkResponse> SetBlockedAsync(string id, bool blocked) =>
        SendAsync<OkResponse>(HttpMethod.Post, "v1/block", new { id, blocked });

    public Task<OkResponse> PublishPrekeysAsync(SignalPublicationDto publication) =>
        SendAsync<OkResponse>(HttpMethod.Post, "v2/prekeys", publication);

    public Task<SignalBundleDto> ClaimPrekeyAsync(string targetId) =>
        SendAsync<SignalBundleDto>(HttpMethod.Post, "v2/prekeys/" + targetId.ToLowerInvariant(), new { });

    public async Task<int> PrekeyCountAsync() =>
        (await SendAsync<PrekeyCountResponse>(HttpMethod.Get, "v2/prekeys")).Available;

    public Task<OkResponse> SendEnvelopeAsync(Envelope env) =>
        SendAsync<OkResponse>(HttpMethod.Post, "v1/envelopes", env);

    public async Task<List<Envelope>> InboxAsync() =>
        (await SendAsync<InboxResponse>(HttpMethod.Get, "v1/inbox")).Envelopes ?? new();

    public Task<OkResponse> AckAsync(IEnumerable<string> ids) =>
        SendAsync<OkResponse>(HttpMethod.Post, "v1/ack", new { ids = ids.ToArray() });

    public void Dispose() => http.Dispose();

    internal sealed class OkResponse { public bool Ok { get; set; } }
    internal sealed class ChallengeResponse { public string Nonce { get; set; } = ""; }
    internal sealed class SessionResponse { public string Token { get; set; } = ""; }
    internal sealed class CodeResponse { public string Code { get; set; } = ""; }
    internal sealed class UsernameLookup { public string Username { get; set; } = ""; public ContactCard Card { get; set; } = new(); }
    internal sealed class InboxResponse { public List<Envelope>? Envelopes { get; set; } }
    internal sealed class PrekeyCountResponse { public int Available { get; set; } }
}