using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace VO1D.Desktop;

public partial class MainWindow : Window
{
    private readonly LocalStore disk = new();
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(3.5) };
    private IdentityCrypto crypto = null!;
    private Vo1dApi api = null!;
    private VaultState state = new();
    private ContactState? selected;
    private bool syncing;
    private string activeWorkspace = "chats";
    private readonly ObservableCollection<RoomVm> rooms = new();
    private readonly ObservableCollection<PersonVm> people = new();
    private readonly ObservableCollection<MessageVm> visibleMessages = new();

    public MainWindow()
    {
        InitializeComponent();
        FitWindowToWorkArea();
        RoomList.ItemsSource = rooms;
        PeopleList.ItemsSource = people;
        MessageList.ItemsSource = visibleMessages;
        Loaded += MainWindow_Loaded;
        SourceInitialized += (_, _) => ApplyWindowsBackdrop();
        poll.Tick += async (_, _) => await SyncAsync();
        Closed += (_, _) =>
        {
            poll.Stop();
            api?.Dispose();
            crypto?.Dispose();
        };
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        StartSplashAnimation();
        await BootAsync();
        await Task.Delay(720);
        HideSplash();
    }

    private void FitWindowToWorkArea()
    {
        var work = SystemParameters.WorkArea;
        Width = Math.Max(MinWidth, Math.Min(1200, work.Width - 28));
        Height = Math.Max(MinHeight, Math.Min(780, work.Height - 28));
        Left = work.Left + Math.Max(0, (work.Width - Width) / 2);
        Top = work.Top + Math.Max(0, (work.Height - Height) / 2);
    }

    private void ApplyWindowsBackdrop()
    {
        try
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            int dark = 1;
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));
            int corner = 2; // round
            DwmSetWindowAttribute(hwnd, 33, ref corner, sizeof(int));
            int backdrop = 2; // mica
            DwmSetWindowAttribute(hwnd, 38, ref backdrop, sizeof(int));
        }
        catch { }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private void StartSplashAnimation()
    {
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        SplashScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(0.78, 1, TimeSpan.FromMilliseconds(720)) { EasingFunction = ease });
        SplashScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(0.78, 1, TimeSpan.FromMilliseconds(720)) { EasingFunction = ease });

        var scan = new DoubleAnimation(-65, 195, TimeSpan.FromMilliseconds(1150))
        {
            RepeatBehavior = RepeatBehavior.Forever
        };
        ScanTransform.BeginAnimation(TranslateTransform.XProperty, scan);
    }

    private void HideSplash()
    {
        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(320));
        fade.Completed += (_, _) =>
        {
            SplashLayer.Visibility = Visibility.Collapsed;
            AnimateMainShell();
        };
        SplashLayer.BeginAnimation(OpacityProperty, fade);
    }

    private void AnimateMainShell()
    {
        MainShell.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(360))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            });
        MainScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(0.985, 1, TimeSpan.FromMilliseconds(420))
            {
                EasingFunction = new BackEase { Amplitude = 0.18, EasingMode = EasingMode.EaseOut }
            });
        MainScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(0.985, 1, TimeSpan.FromMilliseconds(420))
            {
                EasingFunction = new BackEase { Amplitude = 0.18, EasingMode = EasingMode.EaseOut }
            });
    }

    private async Task BootAsync()
    {
        try
        {
            ConnectionText.Text = "ЗАЩИЩАЕМ ЛОКАЛЬНЫЕ КЛЮЧИ…";
            var raw = disk.LoadOrCreateIdentity();
            crypto = new IdentityCrypto(raw);
            state = disk.LoadVault(raw.Storage);
            api = new Vo1dApi(crypto);

            ConnectionText.Text = "ПОДКЛЮЧЕНИЕ К VO1D…";
            await api.AuthenticateAsync();
            state.PublicCode ??= await api.EnsureCodeAsync();
            Save();

            ConnectionText.Text = "ПОДКЛЮЧЁН";
            RelayDot.Fill = new SolidColorBrush(Color.FromArgb(220, 255, 255, 255));
            SettingsCode.Text = state.PublicCode ?? "----";
            SettingsFingerprint.Text = crypto.Card.Id.ToUpperInvariant();
            MiniInitial.Text = string.IsNullOrWhiteSpace(state.Nickname) ? "V" : state.Nickname[..1].ToUpperInvariant();

            RefreshCollections();
            SetNav("chats");
            poll.Start();
            await SyncAsync();

            if (string.IsNullOrWhiteSpace(state.Nickname) || state.Nickname == "Ghost")
            {
                OnboardingLayer.Visibility = Visibility.Visible;
                OnboardingLayer.Opacity = 0;
                OnboardingLayer.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(260)));
                NicknameBox.Focus();
            }
        }
        catch (Exception ex)
        {
            ConnectionText.Text = "НЕТ СВЯЗИ · ЛОКАЛЬНЫЙ VAULT ДОСТУПЕН";
            QueueText.Text = "OFFLINE";
            RelayDot.Fill = new SolidColorBrush(Color.FromArgb(100, 255, 255, 255));
            ShowToast(ex.Message);
            try
            {
                if (crypto != null)
                {
                    SettingsCode.Text = state.PublicCode ?? "----";
                    SettingsFingerprint.Text = crypto.Card.Id.ToUpperInvariant();
                    RefreshCollections();
                }
            }
            catch { }
        }
    }

    private void Save() => disk.SaveVault(state, crypto.Raw.Storage);

    private void RefreshCollections()
    {
        var query = SearchBox.Text?.Trim() ?? "";
        rooms.Clear();
        people.Clear();

        foreach (var contact in state.Contacts.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
        {
            var last = state.Messages
                .Where(x => x.PeerId == contact.Card.Id)
                .OrderBy(x => x.CreatedAt)
                .LastOrDefault();

            var title = string.IsNullOrWhiteSpace(contact.Name)
                ? "Ghost " + contact.Card.Id[..6].ToUpperInvariant()
                : contact.Name;

            people.Add(new PersonVm
            {
                Contact = contact,
                Title = title,
                Initial = title[..1].ToUpperInvariant(),
                Fingerprint = contact.Card.Id[..20].ToUpperInvariant() + "…"
            });

            if (!string.IsNullOrWhiteSpace(query) &&
                !title.Contains(query, StringComparison.OrdinalIgnoreCase) &&
                !(last?.Text.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false))
                continue;

            rooms.Add(new RoomVm
            {
                Contact = contact,
                Title = title,
                Initial = title[..1].ToUpperInvariant(),
                Preview = last?.Text ?? "Начни разговор",
                Time = last == null ? "" : DateTimeOffset.FromUnixTimeSeconds(last.CreatedAt).LocalDateTime.ToString("HH:mm"),
                Unread = 0
            });
        }

        EmptyRooms.Visibility = rooms.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        if (selected != null)
        {
            var vm = rooms.FirstOrDefault(x => x.Contact.Card.Id == selected.Card.Id);
            if (vm != null) RoomList.SelectedItem = vm;
        }
    }

    private void RenderSelected()
    {
        visibleMessages.Clear();

        if (selected == null)
        {
            NoChat.Visibility = Visibility.Visible;
            ComposerBox.IsEnabled = false;
            SendButton.IsEnabled = false;
            ChatTitle.Text = "VO1D Desktop";
            ChatInitial.Text = "V";
            return;
        }

        NoChat.Visibility = Visibility.Collapsed;
        ComposerBox.IsEnabled = true;
        SendButton.IsEnabled = true;
        ChatTitle.Text = selected.Name;
        ChatInitial.Text = string.IsNullOrWhiteSpace(selected.Name) ? "G" : selected.Name[..1].ToUpperInvariant();

        foreach (var m in state.Messages.Where(x => x.PeerId == selected.Card.Id).OrderBy(x => x.CreatedAt))
        {
            visibleMessages.Add(new MessageVm
            {
                Mine = m.Mine,
                Text = m.Text,
                Time = DateTimeOffset.FromUnixTimeSeconds(m.CreatedAt).LocalDateTime.ToString("HH:mm")
            });
        }

        Dispatcher.BeginInvoke(() => MessageScroll.ScrollToEnd(), DispatcherPriority.Background);
    }

    private async void AddContact_Click(object sender, RoutedEventArgs e)
    {
        var value = AddContactBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(value)) return;

        AddError.Visibility = Visibility.Collapsed;
        AddContactButton.IsEnabled = false;
        AddContactButton.Content = "ИЩЕМ…";

        try
        {
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
            if (card.Id == crypto.Card.Id)
                throw new InvalidOperationException("Это твой собственный ID.");

            var existing = state.Contacts.FirstOrDefault(c => c.Card.Id == card.Id);
            if (existing == null)
            {
                existing = new ContactState { Name = name, Card = card };
                state.Contacts.Add(existing);
                Save();
            }

            selected = existing;
            CloseModal();
            RefreshCollections();
            RenderSelected();
            SetNav("chats");
        }
        catch (Exception ex)
        {
            AddError.Text = ex.Message;
            AddError.Visibility = Visibility.Visible;
        }
        finally
        {
            AddContactButton.IsEnabled = true;
            AddContactButton.Content = "ДОБАВИТЬ";
        }
    }

    private async Task SendMessageAsync()
    {
        if (selected == null) return;
        var text = ComposerBox.Text.Trim();
        if (text.Length == 0) return;
        ComposerBox.Clear();

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
            var envelope = crypto.Seal(clear, peer);
            await api.SendEnvelopeAsync(envelope);

            state.Messages.Add(new LocalMessage
            {
                Id = messageId,
                PeerId = peer.Id,
                Mine = true,
                Text = text,
                CreatedAt = now
            });
            Save();
            RefreshCollections();
            RenderSelected();
            AnimateSendButton();
        }
        catch (Exception ex)
        {
            ComposerBox.Text = text;
            ShowToast(ex.Message);
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
                if (state.Processed.Contains(env.Id))
                {
                    ack.Add(env.Id);
                    continue;
                }

                try
                {
                    var contact = state.Contacts.FirstOrDefault(x => x.Card.Id == env.Sender);
                    ContactCard sender;
                    if (contact != null)
                    {
                        sender = contact.Card;
                    }
                    else
                    {
                        sender = await api.LookupIdAsync(env.Sender);
                        contact = new ContactState
                        {
                            Name = "Ghost " + sender.Id[..6].ToUpperInvariant(),
                            Card = sender
                        };
                        state.Contacts.Add(contact);
                    }

                    var clear = crypto.Open(env, sender);
                    using var doc = JsonDocument.Parse(clear);
                    var root = doc.RootElement;

                    // anonymous-v2 on iOS wraps ChatEvent inside a libsignal SignalPacket.
                    // Never ACK what this desktop beta cannot yet authenticate internally.
                    if (root.TryGetProperty("version", out var v) &&
                        v.ValueKind == JsonValueKind.Number &&
                        v.GetInt32() == 2 &&
                        root.TryGetProperty("ciphertext", out _))
                    {
                        QueueText.Text = "SIGNAL V2";
                        continue;
                    }

                    if (root.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.Object)
                    {
                        var body = m.TryGetProperty("text", out var t) ? t.GetString() ?? "" : "";
                        var id = m.TryGetProperty("id", out var mid) ? mid.GetString() ?? Guid.NewGuid().ToString() : Guid.NewGuid().ToString();
                        var at = m.TryGetProperty("createdAt", out var ca) && ca.TryGetInt64(out var sec)
                            ? sec : DateTimeOffset.UtcNow.ToUnixTimeSeconds();

                        if (!state.Messages.Any(x => x.Id == id))
                        {
                            state.Messages.Add(new LocalMessage
                            {
                                Id = id,
                                PeerId = sender.Id,
                                Mine = false,
                                Text = body,
                                CreatedAt = at
                            });
                        }
                    }

                    state.Processed.Add(env.Id);
                    ack.Add(env.Id);
                }
                catch
                {
                    // Auth/decrypt failure stays unacknowledged.
                }
            }

            if (ack.Count > 0) await api.AckAsync(ack);
            Save();
            ConnectionText.Text = "ПОДКЛЮЧЁН";
            QueueText.Text = "E2EE";
            RefreshCollections();
            RenderSelected();
        }
        catch
        {
            ConnectionText.Text = "НЕТ СВЯЗИ · ОЧЕРЕДЬ СОХРАНЕНА";
        }
        finally
        {
            syncing = false;
        }
    }

    private void AnimateSendButton()
    {
        var transform = SendButton.RenderTransform as ScaleTransform;
        if (transform == null)
        {
            transform = new ScaleTransform(1, 1);
            SendButton.RenderTransform = transform;
            SendButton.RenderTransformOrigin = new Point(.5, .5);
        }

        var anim = new DoubleAnimation
        {
            From = 0.86,
            To = 1,
            Duration = TimeSpan.FromMilliseconds(260),
            EasingFunction = new BackEase { Amplitude = 0.35, EasingMode = EasingMode.EaseOut }
        };
        transform.BeginAnimation(ScaleTransform.ScaleXProperty, anim);
        transform.BeginAnimation(ScaleTransform.ScaleYProperty, anim);
    }

    private void SetNav(string workspace)
    {
        activeWorkspace = workspace;
        ChatWorkspace.Visibility = workspace == "chats" ? Visibility.Visible : Visibility.Collapsed;
        PeopleWorkspace.Visibility = workspace == "people" ? Visibility.Visible : Visibility.Collapsed;
        SettingsWorkspace.Visibility = workspace == "settings" ? Visibility.Visible : Visibility.Collapsed;
        RoomsPane.Visibility = workspace == "chats" ? Visibility.Visible : Visibility.Collapsed;

        Grid.SetColumn(PeopleWorkspace, 0);
        Grid.SetColumn(SettingsWorkspace, 0);

        ChatsNav.Background = new SolidColorBrush(workspace == "chats" ? Color.FromArgb(30, 255, 255, 255) : Colors.Transparent);
        PeopleNav.Background = new SolidColorBrush(workspace == "people" ? Color.FromArgb(30, 255, 255, 255) : Colors.Transparent);
        SettingsNav.Background = new SolidColorBrush(workspace == "settings" ? Color.FromArgb(30, 255, 255, 255) : Colors.Transparent);

        var target = workspace == "chats" ? (UIElement)ChatWorkspace :
                     workspace == "people" ? PeopleWorkspace : SettingsWorkspace;
        target.Opacity = 0;
        target.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(220))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            });
    }

    private void ShowToast(string text)
    {
        ConnectionText.Text = text.Length > 52 ? text[..52].ToUpperInvariant() + "…" : text.ToUpperInvariant();
    }

    private void OpenModal()
    {
        ModalLayer.Visibility = Visibility.Visible;
        ModalLayer.Opacity = 0;
        ModalLayer.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
        AddCardScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(0.96, 1, TimeSpan.FromMilliseconds(260)) { EasingFunction = new BackEase { Amplitude = 0.18, EasingMode = EasingMode.EaseOut } });
        AddCardScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(0.96, 1, TimeSpan.FromMilliseconds(260)) { EasingFunction = new BackEase { Amplitude = 0.18, EasingMode = EasingMode.EaseOut } });
        AddContactBox.Clear();
        AddError.Visibility = Visibility.Collapsed;
        AddContactBox.Focus();
    }

    private void CloseModal()
    {
        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(140));
        fade.Completed += (_, _) => ModalLayer.Visibility = Visibility.Collapsed;
        ModalLayer.BeginAnimation(OpacityProperty, fade);
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) ToggleMaximize();
        else DragMove();
    }

    private void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void Maximize_Click(object sender, RoutedEventArgs e) => ToggleMaximize();
    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    private void ToggleMaximize() =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private void ChatsNav_Click(object sender, RoutedEventArgs e) => SetNav("chats");
    private void PeopleNav_Click(object sender, RoutedEventArgs e) => SetNav("people");
    private void SettingsNav_Click(object sender, RoutedEventArgs e) => SetNav("settings");

    private void OpenAddContact_Click(object sender, RoutedEventArgs e) => OpenModal();
    private void CloseModal_Click(object sender, RoutedEventArgs e) => CloseModal();
    private void ModalLayer_MouseDown(object sender, MouseButtonEventArgs e) => CloseModal();
    private void AddCard_MouseDown(object sender, MouseButtonEventArgs e) => e.Handled = true;

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (SearchHint != null) SearchHint.Visibility = string.IsNullOrEmpty(SearchBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        if (crypto != null) RefreshCollections();
    }

    private void RoomList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (RoomList.SelectedItem is not RoomVm vm) return;
        selected = vm.Contact;
        RenderSelected();
    }

    private async void Send_Click(object sender, RoutedEventArgs e) => await SendMessageAsync();

    private async void ComposerBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Keyboard.Modifiers != ModifierKeys.Shift)
        {
            e.Handled = true;
            await SendMessageAsync();
        }
    }

    private void FinishOnboarding_Click(object sender, RoutedEventArgs e)
    {
        var clean = NicknameBox.Text.Trim();
        if (clean.Length == 0) return;
        state.Nickname = clean.Length > 40 ? clean[..40] : clean;
        MiniInitial.Text = state.Nickname[..1].ToUpperInvariant();
        Save();

        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(260));
        fade.Completed += (_, _) => OnboardingLayer.Visibility = Visibility.Collapsed;
        OnboardingLayer.BeginAnimation(OpacityProperty, fade);
    }
}

internal sealed class RoomVm
{
    public ContactState Contact { get; set; } = new();
    public string Title { get; set; } = "";
    public string Initial { get; set; } = "";
    public string Preview { get; set; } = "";
    public string Time { get; set; } = "";
    public int Unread { get; set; }
    public Visibility UnreadVisibility => Unread > 0 ? Visibility.Visible : Visibility.Collapsed;
}

internal sealed class PersonVm
{
    public ContactState Contact { get; set; } = new();
    public string Title { get; set; } = "";
    public string Initial { get; set; } = "";
    public string Fingerprint { get; set; } = "";
}

internal sealed class MessageVm
{
    public bool Mine { get; set; }
    public string Text { get; set; } = "";
    public string Time { get; set; } = "";
}