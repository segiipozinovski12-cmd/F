using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using NSec.Cryptography;

namespace VO1D.Desktop;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
    }
}

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
    public override string ToString() => Name;
}

internal sealed class LocalMessage
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string PeerId { get; set; } = "";
    public bool Mine { get; set; }
    public string Text { get; set; } = "";
    public long CreatedAt { get; set; }
}

internal sealed class VaultState
{
    public string Nickname { get; set; } = "Ghost";
    public string? PublicCode { get; set; }
    public string? Username { get; set; }
    public List<ContactState> Contacts { get; set; } = new();
    public List<LocalMessage> Messages { get; set; } = new();
    public HashSet<string> Processed { get; set; } = new();
}

internal sealed class IdentityCrypto : IDisposable
{
    private static readonly SignatureAlgorithm Ed = SignatureAlgorithm.Ed25519;
    private static readonly KeyAgreementAlgorithm X = KeyAgreementAlgorithm.X25519;
    private static KeyCreationParameters Exportable() => new()
    {
        ExportPolicy = KeyExportPolicies.AllowPlaintextExport
    };

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
                AgreementKey = Convert.ToBase64String(agreePub),
                Binding = ""
            };
            card.Binding = Convert.ToBase64String(Ed.Sign(signing, CardBytes(card)));
            return card;
        }
    }

    public byte[] Sign(ReadOnlySpan<byte> data) => Ed.Sign(signing, data);

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
        using var pub = PublicKey.Import(Ed, sign, KeyBlobFormat.RawPublicKey);
        if (!Ed.Verify(pub, CardBytes(card), binding))
            throw new InvalidDataException("Подпись контакта не прошла проверку");
    }

    public Envelope Seal(byte[] clear, ContactCard recipient)
    {
        Validate(recipient);
        var own = Card;
        using var ephemeral = new Key(X, Exportable());
        using var remote = PublicKey.Import(X, Convert.FromBase64String(recipient.AgreementKey), KeyBlobFormat.RawPublicKey);
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

        var key = KeyDerivationAlgorithm.HkdfSha256.DeriveBytes(
            shared,
            Convert.FromBase64String(env.Salt),
            env.Header,
            32);

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

        using (var signPub = PublicKey.Import(Ed, Convert.FromBase64String(sender.SigningKey), KeyBlobFormat.RawPublicKey))
        {
            if (!Ed.Verify(signPub, signed, Convert.FromBase64String(env.Signature)))
                throw new InvalidDataException("Подпись сообщения не прошла проверку");
        }

        using var eph = PublicKey.Import(X, Convert.FromBase64String(env.EphemeralKey), KeyBlobFormat.RawPublicKey);
        using var shared = X.Agree(agreement, eph) ?? throw new CryptographicException("X25519 key agreement failed");
        var key = KeyDerivationAlgorithm.HkdfSha256.DeriveBytes(
            shared,
            Convert.FromBase64String(env.Salt),
            env.Header,
            32);

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
    private readonly string root;
    private readonly string identityPath;
    private readonly string vaultPath;

    public LocalStore()
    {
        root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VO1D");
        Directory.CreateDirectory(root);
        identityPath = Path.Combine(root, "identity.dpapi");
        vaultPath = Path.Combine(root, "vault.bin");
    }

    public LocalIdentity LoadOrCreateIdentity()
    {
        if (File.Exists(identityPath))
        {
            var protectedBytes = File.ReadAllBytes(identityPath);
            var clear = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<LocalIdentity>(clear, AppJson.Options)
                   ?? throw new InvalidDataException("Не удалось прочитать identity");
        }

        var identity = IdentityCrypto.Create();
        var json = JsonSerializer.SerializeToUtf8Bytes(identity, AppJson.Options);
        var protectedBytesNew = ProtectedData.Protect(json, null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(identityPath, protectedBytesNew);
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
                detail = doc.RootElement.TryGetProperty("error", out var e) ? e.GetString() ?? res.ReasonPhrase ?? "server error" : res.ReasonPhrase ?? "server error";
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
        var signature = Convert.ToBase64String(identity.Sign(auth));
        var session = await SendAsync<SessionResponse>(HttpMethod.Post, "v1/session",
            new { id = identity.Card.Id, nonce = challenge.Nonce, signature }, false);
        token = session.Token;
    }

    public async Task<string> EnsureCodeAsync()
    {
        var r = await SendAsync<CodeResponse>(HttpMethod.Post, "v1/code", new { });
        return r.Code;
    }

    public Task<ContactCard> LookupCodeAsync(string code) =>
        SendAsync<ContactCard>(HttpMethod.Get, "v1/code/" + Uri.EscapeDataString(code.ToUpperInvariant()));

    public async Task<ContactCard> LookupUsernameAsync(string username)
    {
        var clean = username.Trim().TrimStart('@').ToLowerInvariant();
        var r = await SendAsync<UsernameLookup>(HttpMethod.Get, "v1/username/" + Uri.EscapeDataString(clean));
        return r.Card;
    }

    public Task<ContactCard> LookupIdAsync(string id) =>
        SendAsync<ContactCard>(HttpMethod.Get, "v1/identity/" + id.ToLowerInvariant());

    public Task<OkResponse> SendEnvelopeAsync(Envelope env) =>
        SendAsync<OkResponse>(HttpMethod.Post, "v1/envelopes", env);

    public async Task<List<Envelope>> InboxAsync()
    {
        var r = await SendAsync<InboxResponse>(HttpMethod.Get, "v1/inbox");
        return r.Envelopes ?? new();
    }

    public Task<OkResponse> AckAsync(IEnumerable<string> ids) =>
        SendAsync<OkResponse>(HttpMethod.Post, "v1/ack", new { ids = ids.ToArray() });

    public void Dispose() => http.Dispose();

    internal sealed class OkResponse { public bool Ok { get; set; } }
    internal sealed class ChallengeResponse { public string Nonce { get; set; } = ""; }
    internal sealed class SessionResponse { public string Token { get; set; } = ""; }
    internal sealed class CodeResponse { public string Code { get; set; } = ""; }
    internal sealed class UsernameLookup { public string Username { get; set; } = ""; public ContactCard Card { get; set; } = new(); }
    internal sealed class InboxResponse { public List<Envelope>? Envelopes { get; set; } }
}

internal sealed class MainForm : Form
{
    private readonly Color bg = Color.FromArgb(8, 8, 8);
    private readonly Color panel = Color.FromArgb(16, 16, 16);
    private readonly Color line = Color.FromArgb(38, 38, 38);
    private readonly Color muted = Color.FromArgb(155, 155, 155);

    private readonly ListBox contacts = new();
    private readonly FlowLayoutPanel messages = new();
    private readonly TextBox composer = new();
    private readonly TextBox addBox = new();
    private readonly Label title = new();
    private readonly Label status = new();
    private readonly Label identityLabel = new();
    private readonly Button send = new();
    private readonly Button add = new();
    private readonly System.Windows.Forms.Timer poll = new() { Interval = 3500 };

    private readonly LocalStore disk = new();
    private IdentityCrypto crypto = null!;
    private Vo1dApi api = null!;
    private VaultState state = new();
    private ContactState? selected;
    private bool syncing;

    public MainForm()
    {
        Text = "VO1D";
        Width = 1180;
        Height = 760;
        MinimumSize = new Size(900, 620);
        BackColor = bg;
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 10f);
        StartPosition = FormStartPosition.CenterScreen;

        BuildUi();
        Shown += async (_, _) => await BootAsync();
        poll.Tick += async (_, _) => await SyncAsync();
        FormClosed += (_, _) => { poll.Stop(); api?.Dispose(); crypto?.Dispose(); };
    }

    private void BuildUi()
    {
        var left = new Panel { Dock = DockStyle.Left, Width = 310, BackColor = panel, Padding = new Padding(18) };
        Controls.Add(left);

        var brand = new Label
        {
            Text = "VO1D",
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 23f, FontStyle.Bold),
            ForeColor = Color.White,
            Location = new Point(18, 16)
        };
        left.Controls.Add(brand);

        identityLabel.AutoSize = false;
        identityLabel.Width = 270;
        identityLabel.Height = 42;
        identityLabel.Location = new Point(18, 62);
        identityLabel.ForeColor = muted;
        identityLabel.Text = "инициализация…";
        left.Controls.Add(identityLabel);

        addBox.Location = new Point(18, 116);
        addBox.Width = 196;
        addBox.PlaceholderText = "ID / @username";
        DarkTextBox(addBox);
        left.Controls.Add(addBox);

        add.Text = "+";
        add.Width = 52;
        add.Height = 30;
        add.Location = new Point(220, 114);
        DarkButton(add);
        add.Click += async (_, _) => await AddContactAsync();
        left.Controls.Add(add);

        contacts.Location = new Point(18, 160);
        contacts.Width = 270;
        contacts.Height = 520;
        contacts.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        contacts.BackColor = panel;
        contacts.ForeColor = Color.White;
        contacts.BorderStyle = BorderStyle.None;
        contacts.Font = new Font("Segoe UI", 11f);
        contacts.ItemHeight = 36;
        contacts.SelectedIndexChanged += (_, _) =>
        {
            selected = contacts.SelectedItem as ContactState;
            RenderSelected();
        };
        left.Controls.Add(contacts);

        var top = new Panel { Dock = DockStyle.Top, Height = 80, BackColor = bg, Padding = new Padding(24, 18, 24, 10) };
        Controls.Add(top);

        title.AutoSize = true;
        title.Text = "Desktop";
        title.Font = new Font("Segoe UI Semibold", 17f, FontStyle.Bold);
        title.Location = new Point(24, 14);
        top.Controls.Add(title);

        status.AutoSize = true;
        status.Text = "offline";
        status.ForeColor = muted;
        status.Location = new Point(26, 48);
        top.Controls.Add(status);

        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 82, BackColor = bg, Padding = new Padding(22, 18, 22, 18) };
        Controls.Add(bottom);

        composer.Dock = DockStyle.Fill;
        composer.PlaceholderText = "Сообщение";
        DarkTextBox(composer);
        composer.KeyDown += async (_, e) =>
        {
            if (e.KeyCode == Keys.Enter && !e.Shift)
            {
                e.SuppressKeyPress = true;
                await SendMessageAsync();
            }
        };
        bottom.Controls.Add(composer);

        send.Text = "Отправить";
        send.Dock = DockStyle.Right;
        send.Width = 110;
        DarkButton(send);
        send.Click += async (_, _) => await SendMessageAsync();
        bottom.Controls.Add(send);

        messages.Dock = DockStyle.Fill;
        messages.FlowDirection = FlowDirection.TopDown;
        messages.WrapContents = false;
        messages.AutoScroll = true;
        messages.Padding = new Padding(26, 18, 26, 18);
        messages.BackColor = bg;
        messages.Resize += (_, _) => ResizeBubbles();
        Controls.Add(messages);

        var sep = new Panel { Dock = DockStyle.Left, Width = 1, BackColor = line };
        Controls.Add(sep);
    }

    private void DarkTextBox(TextBox box)
    {
        box.BackColor = Color.FromArgb(23, 23, 23);
        box.ForeColor = Color.White;
        box.BorderStyle = BorderStyle.FixedSingle;
    }

    private void DarkButton(Button button)
    {
        button.BackColor = Color.White;
        button.ForeColor = Color.Black;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.Cursor = Cursors.Hand;
    }

    private async Task BootAsync()
    {
        try
        {
            status.Text = "защищаю локальные ключи…";
            var raw = disk.LoadOrCreateIdentity();
            crypto = new IdentityCrypto(raw);
            state = disk.LoadVault(raw.Storage);
            api = new Vo1dApi(crypto);

            status.Text = "подключение к VO1D relay…";
            await api.AuthenticateAsync();
            state.PublicCode ??= await api.EnsureCodeAsync();
            Save();

            identityLabel.Text = $"VO1D ID  {state.PublicCode}\r\n{crypto.Card.Id[..12].ToUpperInvariant()}";
            RefreshContacts();
            status.Text = "подключён · relay online";
            poll.Start();
            await SyncAsync();
        }
        catch (Exception ex)
        {
            status.Text = "ошибка подключения";
            MessageBox.Show(this, ex.Message, "VO1D", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void Save() => disk.SaveVault(state, crypto.Raw.Storage);

    private void RefreshContacts()
    {
        var current = selected?.Card.Id;
        contacts.BeginUpdate();
        contacts.Items.Clear();
        foreach (var c in state.Contacts.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
            contacts.Items.Add(c);
        contacts.EndUpdate();

        if (current != null)
        {
            for (int i = 0; i < contacts.Items.Count; i++)
                if (((ContactState)contacts.Items[i]).Card.Id == current) { contacts.SelectedIndex = i; break; }
        }
    }

    private async Task AddContactAsync()
    {
        var value = addBox.Text.Trim();
        if (value.Length == 0) return;
        try
        {
            status.Text = "ищу контакт…";
            ContactCard card;
            string name;
            if (value.Length == 4)
            {
                card = await api.LookupCodeAsync(value);
                name = "Ghost " + card.Id[..6].ToUpperInvariant();
            }
            else if (value.StartsWith("@") || value.Length is >= 4 and <= 20)
            {
                card = await api.LookupUsernameAsync(value);
                name = value.StartsWith("@") ? value : "@" + value;
            }
            else
            {
                card = await api.LookupIdAsync(value);
                name = "Ghost " + card.Id[..6].ToUpperInvariant();
            }

            IdentityCrypto.Validate(card);
            if (card.Id == crypto.Card.Id) throw new InvalidOperationException("Это твой собственный ID");
            var existing = state.Contacts.FirstOrDefault(c => c.Card.Id == card.Id);
            if (existing == null)
            {
                existing = new ContactState { Name = name, Card = card };
                state.Contacts.Add(existing);
                Save();
            }

            RefreshContacts();
            contacts.SelectedItem = existing;
            addBox.Clear();
            status.Text = "контакт добавлен";
        }
        catch (Exception ex)
        {
            status.Text = "не удалось добавить";
            MessageBox.Show(this, ex.Message, "VO1D", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task SendMessageAsync()
    {
        if (selected == null || string.IsNullOrWhiteSpace(composer.Text)) return;
        var text = composer.Text.Trim();
        composer.Clear();

        try
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var own = crypto.Card;
            var peer = selected.Card;
            var roomId = "dm:" + string.Join(":", new[] { own.Id, peer.Id }.OrderBy(x => x, StringComparer.Ordinal));

            var room = new
            {
                id = roomId,
                title = selected.Name,
                members = new[] { own, peer },
                creator = "",
                isGroup = false,
                createdAt = now,
                pinned = false,
                archived = false,
                muted = false,
                unread = 0,
                draft = "",
                disappearingSeconds = 0,
                admins = (string[]?)null,
                onlyAdminsCanPost = (bool?)null,
                pinnedMessageIDs = (string[]?)null,
                isChannel = (bool?)null,
                topics = (string[]?)null,
                mutedUntil = (long?)null,
                privateRoster = (bool?)null,
                membershipEpoch = (int?)null
            };

            var messageId = Guid.NewGuid().ToString();
            var message = new
            {
                id = messageId,
                roomID = roomId,
                sender = own.Id,
                text,
                createdAt = now,
                expiresAt = (long?)null,
                replyTo = (string?)null,
                attachment = (object?)null,
                state = "sent",
                edited = false,
                reactions = new Dictionary<string, string>(),
                readBy = Array.Empty<string>(),
                deliveredTo = Array.Empty<string>(),
                openedAt = (long?)null,
                forwardedFrom = (string?)null,
                scheduledAt = (long?)null,
                silent = (bool?)null,
                editHistory = (string[]?)null,
                poll = (object?)null,
                topic = (string?)null,
                call = (object?)null
            };

            var ev = new
            {
                deviceCertificate = (object?)null,
                historyArchive = (object?)null,
                groupInvitation = (object?)null,
                replyMailbox = (object?)null,
                id = Guid.NewGuid().ToString(),
                kind = "message",
                room,
                message,
                target = (string?)null,
                value = (string?)null,
                senderName = state.Nickname,
                padding = (string?)null,
                at = now
            };

            var clear = JsonSerializer.SerializeToUtf8Bytes(ev, AppJson.Options);
            var envelope = crypto.Seal(clear, selected.Card);
            await api.SendEnvelopeAsync(envelope);

            state.Messages.Add(new LocalMessage { Id = messageId, PeerId = peer.Id, Mine = true, Text = text, CreatedAt = now });
            Save();
            RenderSelected();
            status.Text = "отправлено";
        }
        catch (Exception ex)
        {
            composer.Text = text;
            status.Text = "ошибка отправки";
            MessageBox.Show(this,
                ex.Message + "\r\n\r\nВажно: текущий Windows beta использует совместимый внешний VO1D envelope. Полный libsignal-v2 слой мобильной ветки переносится отдельно.",
                "VO1D", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task SyncAsync()
    {
        if (syncing || api == null) return;
        syncing = true;
        try
        {
            var inbox = await api.InboxAsync();
            var ack = new List<string>();

            foreach (var env in inbox)
            {
                if (state.Processed.Contains(env.Id)) { ack.Add(env.Id); continue; }
                try
                {
                    var contact = state.Contacts.FirstOrDefault(x => x.Card.Id == env.Sender);
                    ContactCard sender;
                    if (contact != null) sender = contact.Card;
                    else
                    {
                        sender = await api.LookupIdAsync(env.Sender);
                        contact = new ContactState { Name = "Ghost " + sender.Id[..6].ToUpperInvariant(), Card = sender };
                        state.Contacts.Add(contact);
                    }

                    var clear = crypto.Open(env, sender);
                    using var doc = JsonDocument.Parse(clear);
                    var root = doc.RootElement;

                    // Full mobile v2 wraps the ChatEvent in a SignalPacket. The desktop beta
                    // deliberately refuses to fake-decrypt it and leaves the limitation visible.
                    if (root.TryGetProperty("version", out var version) && version.GetInt32() == 2 &&
                        root.TryGetProperty("ciphertext", out _))
                    {
                        status.Text = "получен libsignal-v2 пакет · нужен desktop v2 слой";
                    }
                    else if (root.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.Object)
                    {
                        var text = m.TryGetProperty("text", out var t) ? t.GetString() ?? "" : "";
                        var id = m.TryGetProperty("id", out var mid) ? mid.GetString() ?? Guid.NewGuid().ToString() : Guid.NewGuid().ToString();
                        var at = m.TryGetProperty("createdAt", out var ca) && ca.TryGetInt64(out var sec)
                            ? sec : DateTimeOffset.UtcNow.ToUnixTimeSeconds();

                        if (!state.Messages.Any(x => x.Id == id))
                            state.Messages.Add(new LocalMessage { Id = id, PeerId = sender.Id, Mine = false, Text = text, CreatedAt = at });
                    }

                    state.Processed.Add(env.Id);
                    ack.Add(env.Id);
                }
                catch
                {
                    // Do not ACK ciphertext that could not be authenticated/decrypted.
                }
            }

            if (ack.Count > 0) await api.AckAsync(ack);
            Save();
            RefreshContacts();
            RenderSelected();
            if (status.Text.StartsWith("подключ")) status.Text = "подключён · синхронизация";
        }
        catch
        {
            status.Text = "нет связи · локальные данные сохранены";
        }
        finally { syncing = false; }
    }

    private void RenderSelected()
    {
        title.Text = selected?.Name ?? "VO1D Desktop";
        messages.SuspendLayout();
        messages.Controls.Clear();

        if (selected == null)
        {
            AddInfo("Выбери контакт слева или добавь VO1D ID / @username.");
            messages.ResumeLayout();
            return;
        }

        foreach (var m in state.Messages.Where(x => x.PeerId == selected.Card.Id).OrderBy(x => x.CreatedAt))
            AddBubble(m);
        messages.ResumeLayout();
        ResizeBubbles();
        if (messages.Controls.Count > 0) messages.ScrollControlIntoView(messages.Controls[^1]);
    }

    private void AddInfo(string text)
    {
        var label = new Label
        {
            Text = text,
            ForeColor = muted,
            AutoSize = false,
            Height = 42,
            TextAlign = ContentAlignment.MiddleCenter,
            Margin = new Padding(8),
            Width = Math.Max(200, messages.ClientSize.Width - 70)
        };
        messages.Controls.Add(label);
    }

    private void AddBubble(LocalMessage m)
    {
        var holder = new Panel
        {
            Height = 58,
            Margin = new Padding(0, 4, 0, 4),
            BackColor = bg
        };
        var bubble = new Label
        {
            Text = m.Text,
            AutoSize = false,
            Height = 48,
            Padding = new Padding(12, 8, 12, 8),
            BackColor = m.Mine ? Color.White : Color.FromArgb(30, 30, 30),
            ForeColor = m.Mine ? Color.Black : Color.White,
            Font = new Font("Segoe UI", 10.5f),
            TextAlign = ContentAlignment.MiddleLeft
        };
        holder.Controls.Add(bubble);
        holder.Tag = (bubble, m.Mine);
        messages.Controls.Add(holder);
    }

    private void ResizeBubbles()
    {
        var width = Math.Max(300, messages.ClientSize.Width - 65);
        foreach (Control c in messages.Controls)
        {
            c.Width = width;
            if (c.Tag is ValueTuple<Label, bool> data)
            {
                var bubble = data.Item1;
                bubble.Width = Math.Min(560, Math.Max(180, width * 2 / 3));
                bubble.Left = data.Item2 ? width - bubble.Width : 0;
                bubble.Top = 5;
            }
            else c.Width = width;
        }
    }
}
