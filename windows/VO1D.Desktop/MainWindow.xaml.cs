using System.Collections.ObjectModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace VO1D.Desktop;

public partial class MainWindow : Window
{
    private readonly LocalStore disk = new();
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(3.5) };
    private readonly ObservableCollection<RoomVm> rooms = new();
    private readonly ObservableCollection<PersonVm> people = new();
    private readonly ObservableCollection<MessageVm> visibleMessages = new();
    private readonly ObservableCollection<ToolsItemVm> toolsItems = new();

    private IdentityCrypto crypto = null!;
    private Vo1dApi api = null!;
    private SignalBridgeClient? signal;
    private VaultState state = new();
    private RoomState? selectedRoom;
    private ContactState? selected;
    private AttachmentState? pendingAttachment;
    private string? replyingToId;
    private string? editingId;
    private bool syncing;
    private bool loadingComposer;
    private string activeWorkspace = "chats";
    private string roomFilter = "all";
    private string peopleFilter = "all";

    public MainWindow()
    {
        InitializeComponent();
        FitWindowToWorkArea();

        RoomList.ItemsSource = rooms;
        PeopleList.ItemsSource = people;
        ComposePeopleList.ItemsSource = people;
        MessageList.ItemsSource = visibleMessages;
        ToolsList.ItemsSource = toolsItems;

        Loaded += MainWindow_Loaded;
        SourceInitialized += (_, _) => ApplyWindowsBackdrop();
        poll.Tick += async (_, _) =>
        {
            ExpireMessages();
            ApplyLocalRetention();
            CheckLocalReminders();
            await FlushScheduledAsync();
            await SyncAsync();
        };
        Closed += (_, _) =>
        {
            poll.Stop();
            VoiceCleanup();
            signal?.Dispose();
            api?.Dispose();
            crypto?.Dispose();
        };
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        StartSplashAnimation();
        StartBackdropAnimations();
        await BootAsync();
        await Task.Delay(720);
        HideSplash();
    }

    private void FitWindowToWorkArea()
    {
        var work = SystemParameters.WorkArea;
        Width = Math.Max(MinWidth, Math.Min(1260, work.Width - 28));
        Height = Math.Max(MinHeight, Math.Min(820, work.Height - 28));
        Left = work.Left + Math.Max(0, (work.Width - Width) / 2);
        Top = work.Top + Math.Max(0, (work.Height - Height) / 2);
    }

    private void Window_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (RoomsColumn == null) return;
        if (ActualWidth < 1000)
        {
            NavColumn.Width = new GridLength(68);
            RoomsColumn.Width = new GridLength(285);
            GapOne.Width = new GridLength(8);
            GapTwo.Width = new GridLength(8);

            if (RoomsTitle != null)
            {
                RoomsTitle.FontSize = 23;
                RoomsTitle.Margin = new Thickness(0, 17, 78, 0);
            }
            if (SavedButton != null) { SavedButton.Width = 36; SavedButton.Height = 36; }
            if (ComposeButton != null) { ComposeButton.Width = 42; ComposeButton.Height = 42; }
        }
        else if (ActualWidth < 1160)
        {
            NavColumn.Width = new GridLength(72);
            RoomsColumn.Width = new GridLength(330);
            GapOne.Width = new GridLength(10);
            GapTwo.Width = new GridLength(10);

            if (RoomsTitle != null)
            {
                RoomsTitle.FontSize = 26;
                RoomsTitle.Margin = new Thickness(0, 17, 84, 0);
            }
            if (SavedButton != null) { SavedButton.Width = 38; SavedButton.Height = 38; }
            if (ComposeButton != null) { ComposeButton.Width = 44; ComposeButton.Height = 44; }
        }
        else
        {
            NavColumn.Width = new GridLength(78);
            RoomsColumn.Width = new GridLength(370);
            GapOne.Width = new GridLength(12);
            GapTwo.Width = new GridLength(12);

            if (RoomsTitle != null)
            {
                RoomsTitle.FontSize = 28;
                RoomsTitle.Margin = new Thickness(0, 17, 88, 0);
            }
            if (SavedButton != null) { SavedButton.Width = 40; SavedButton.Height = 40; }
            if (ComposeButton != null) { ComposeButton.Width = 46; ComposeButton.Height = 46; }
        }
    }

    private void ApplyWindowsBackdrop()
    {
        try
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            int dark = 1;
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));
            int corner = 2;
            DwmSetWindowAttribute(hwnd, 33, ref corner, sizeof(int));
            int backdrop = 2;
            DwmSetWindowAttribute(hwnd, 38, ref backdrop, sizeof(int));
        }
        catch { }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private void StartBackdropAnimations()
    {
        GlowATransform.BeginAnimation(TranslateTransform.XProperty,
            new DoubleAnimation(-30, 90, TimeSpan.FromSeconds(14))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
        GlowATransform.BeginAnimation(TranslateTransform.YProperty,
            new DoubleAnimation(-20, 55, TimeSpan.FromSeconds(17))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
        GlowBTransform.BeginAnimation(TranslateTransform.XProperty,
            new DoubleAnimation(40, -80, TimeSpan.FromSeconds(16))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
        GlowCScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(.86, 1.18, TimeSpan.FromSeconds(10))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
        GlowCScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(.86, 1.18, TimeSpan.FromSeconds(10))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
    }

    private void StartSplashAnimation()
    {
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        SplashScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(0.78, 1, TimeSpan.FromMilliseconds(720)) { EasingFunction = ease });
        SplashScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(0.78, 1, TimeSpan.FromMilliseconds(720)) { EasingFunction = ease });

        ScanTransform.BeginAnimation(TranslateTransform.XProperty,
            new DoubleAnimation(-65, 195, TimeSpan.FromMilliseconds(1150))
            { RepeatBehavior = RepeatBehavior.Forever });
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
            { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
        var scale = new DoubleAnimation(0.985, 1, TimeSpan.FromMilliseconds(420))
        { EasingFunction = new BackEase { Amplitude = 0.18, EasingMode = EasingMode.EaseOut } };
        MainScale.BeginAnimation(ScaleTransform.ScaleXProperty, scale);
        MainScale.BeginAnimation(ScaleTransform.ScaleYProperty, scale);
    }

    private async Task BootAsync()
    {
        try
        {
            ConnectionText.Text = "ЗАЩИЩАЕМ ЛОКАЛЬНЫЕ КЛЮЧИ…";
            var raw = disk.LoadOrCreateIdentity();
            crypto = new IdentityCrypto(raw);

            if (Environment.GetEnvironmentVariable("VO1D_UI_PREVIEW") == "1")
            {
                SeedUiPreview();
                ApplySettingsToUi();
                RefreshAll();
                SetNav("chats");
                ConnectionText.Text = "ПОДКЛЮЧЁН";
                RelayDot.Fill = new SolidColorBrush(Color.FromArgb(220, 255, 255, 255));
                return;
            }

            state = disk.LoadVault(raw.Storage);
            EnsureMigratedState();

            if (state.AppLock && !sessionUnlocked)
            {
                SettingsCode.Text = state.PublicCode ?? "----";
                SettingsFingerprint.Text = crypto.Card.Id.ToUpperInvariant();
                ApplySettingsToUi();
                UpdateSecurityUi();
                RefreshAll();
                ConnectionText.Text = "ЗАБЛОКИРОВАНО";
                QueueText.Text = "LOCKED";
                LockLayer.Visibility = Visibility.Visible;
                LockPinBox.Focus();
                return;
            }

            signal = new SignalBridgeClient();
            state.SignalSnapshotJson ??= await signal.CreateSnapshotAsync();

            api = new Vo1dApi(crypto);
            ConnectionText.Text = "ПОДКЛЮЧЕНИЕ К VO1D…";
            await api.AuthenticateAsync();
            state.PublicCode ??= await api.EnsureCodeAsync();
            await EnsureSignalReadyAsync();
            Save();

            ConnectionText.Text = "ПОДКЛЮЧЁН";
            RelayDot.Fill = new SolidColorBrush(Color.FromArgb(220, 255, 255, 255));
            ApplySettingsToUi();
            UpdateSecurityUi();
            RefreshAll();
            SetNav("chats");
            poll.Interval = state.Preferences.LowData ? TimeSpan.FromSeconds(8) : TimeSpan.FromSeconds(3.5);
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
                    EnsureMigratedState();
                    ApplySettingsToUi();
                    RefreshAll();
                }
            }
            catch { }
        }
    }

    private void SeedUiPreview()
    {
        var own = crypto.Card.Id;
        state = new VaultState
        {
            Nickname = "VO1D",
            PublicCode = "V01D",
            Preferences = new DesktopPreferences { TextScale = 100 }
        };

        var room = new RoomState
        {
            Id = "preview:room",
            Title = "VO1D Design QA",
            MemberIds = new List<string> { own },
            Creator = own,
            IsGroup = true,
            CreatedAt = DateTimeOffset.UtcNow.AddHours(-2).ToUnixTimeSeconds(),
            Pinned = true
        };
        state.Rooms.Add(room);

        state.Messages.AddRange(new[]
        {
            new LocalMessage
            {
                Id = "preview-1",
                RoomId = room.Id,
                SenderId = "preview",
                Mine = false,
                Text = "Windows теперь проверяется по реальному рендеру, а не только по сборке.",
                CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-18).ToUnixTimeSeconds(),
                State = "sent"
            },
            new LocalMessage
            {
                Id = "preview-2",
                RoomId = room.Id,
                SenderId = own,
                Mine = true,
                Text = "Супер. Composer, bubbles, карточки, стекло и адаптивность должны выглядеть не хуже iOS.",
                CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-16).ToUnixTimeSeconds(),
                State = "sent",
                Reactions = new Dictionary<string,string> { ["preview"] = "🔥" }
            },
            new LocalMessage
            {
                Id = "preview-3",
                RoomId = room.Id,
                SenderId = "preview",
                Mine = false,
                Text = "Reply, edit, reactions, attachments, saved messages и scheduled send уже в Windows ветке.",
                CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-8).ToUnixTimeSeconds(),
                State = "sent",
                ReplyTo = "preview-2"
            }
        });

        selectedRoom = room;
        selected = null;
    }

    private void EnsureMigratedState()
    {
        state.Contacts ??= new();
        state.Rooms ??= new();
        state.Messages ??= new();
        state.Processed ??= new();
        state.HiddenRooms ??= new();
        state.Folders ??= new();
        state.Reminders ??= new();
        state.Snippets ??= new();
        state.RoomRetentionDays ??= new();
        state.RoomTextScale ??= new();
        state.RoomNotes ??= new();
        state.Preferences ??= new DesktopPreferences();

        var own = crypto.Card.Id;
        foreach (var contact in state.Contacts)
        {
            var id = DmRoomId(contact.Card.Id);
            if (state.Rooms.All(x => x.Id != id))
            {
                state.Rooms.Add(new RoomState
                {
                    Id = id,
                    Title = contact.Name,
                    MemberIds = new List<string> { own, contact.Card.Id },
                    Creator = own,
                    CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
                });
            }
        }

        foreach (var message in state.Messages)
        {
            if (string.IsNullOrWhiteSpace(message.RoomId) && !string.IsNullOrWhiteSpace(message.PeerId))
                message.RoomId = DmRoomId(message.PeerId);
            if (string.IsNullOrWhiteSpace(message.SenderId))
                message.SenderId = message.Mine ? own : message.PeerId;
        }

        state.Rooms.RemoveAll(r => string.IsNullOrWhiteSpace(r.Id));

        var savedId = SavedRoomId;
        if (state.Rooms.All(r => r.Id != savedId))
        {
            state.Rooms.Add(new RoomState
            {
                Id = savedId,
                Title = "Сохранённые",
                MemberIds = new List<string> { own },
                Creator = own,
                CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                Pinned = true
            });
        }
        Save();
    }

    private string DmRoomId(string peerId) =>
        "dm:" + string.Join(":", new[] { crypto.Card.Id, peerId }.OrderBy(x => x, StringComparer.Ordinal));

    private string SavedRoomId => "saved:" + crypto.Card.Id;
    private bool IsSavedRoom(RoomState? room) => room != null && room.Id == SavedRoomId;

    private void Save() => disk.SaveVault(state, crypto.Raw.Storage);

    private async Task EnsureSignalReadyAsync()
    {
        if (signal == null) throw new InvalidOperationException("Signal runtime не запущен.");
        state.SignalSnapshotJson ??= await signal.CreateSnapshotAsync();

        var count = await api.PrekeyCountAsync();
        if (count < 8)
        {
            var publication = await signal.PublicationAsync(state.SignalSnapshotJson, crypto.Card.Id, 24);
            foreach (var bundle in publication.Bundles)
                crypto.CompleteSignalBundle(bundle);

            await api.PublishPrekeysAsync(new SignalPublicationDto { Bundles = publication.Bundles });
            state.SignalSnapshotJson = publication.SnapshotJson;
            Save();
        }

        ProtocolStatus.Text = "Signal v2 · PQXDH + Double Ratchet · libsignal 0.70.0";
        QueueText.Text = "SIGNAL V2";
    }

    private async Task<Envelope> SealSignalAsync(byte[] clear, ContactCard target)
    {
        if (signal == null) throw new InvalidOperationException("Signal runtime не запущен.");
        state.SignalSnapshotJson ??= await signal.CreateSnapshotAsync();

        var session = await signal.HasSessionAsync(state.SignalSnapshotJson, target.Id);
        state.SignalSnapshotJson = session.SnapshotJson;

        SignalBundleDto? bundle = null;
        if (!session.HasSession)
        {
            bundle = await api.ClaimPrekeyAsync(target.Id);
            IdentityCrypto.ValidateSignalBundle(bundle, target);
        }

        var encrypted = await signal.EncryptAsync(state.SignalSnapshotJson, target.Id, clear, bundle);
        state.SignalSnapshotJson = encrypted.SnapshotJson;
        crypto.CompleteSignalPacket(encrypted.Packet);

        var packetBytes = JsonSerializer.SerializeToUtf8Bytes(encrypted.Packet, AppJson.Options);
        var envelope = crypto.Seal(packetBytes, target);
        Save();
        return envelope;
    }

    private void ApplySettingsToUi()
    {
        SettingsCode.Text = state.PublicCode ?? "----";
        SettingsFingerprint.Text = crypto.Card.Id.ToUpperInvariant();
        MiniInitial.Text = string.IsNullOrWhiteSpace(state.Nickname) ? "V" : state.Nickname[..1].ToUpperInvariant();

        CompactRowsToggle.IsChecked = state.Preferences.CompactRows;
        HideMediaToggle.IsChecked = state.Preferences.HideMedia;
        ProtectCaptureToggle.IsChecked = state.Preferences.ProtectCapture;
        LowDataToggle.IsChecked = state.Preferences.LowData;
        ConfirmLinksToggle.IsChecked = state.Preferences.ConfirmLinks;
        CleanLinksToggle.IsChecked = state.Preferences.CleanLinks;
        QuietHoursToggle.IsChecked = state.Preferences.QuietHours;
    }

    private void RefreshAll()
    {
        RefreshCollections();
        RefreshPeople();
        RefreshTools();
        RenderSelected();
    }

    private void RefreshCollections()
    {
        var query = SearchBox.Text?.Trim() ?? "";
        var previous = selectedRoom?.Id;
        rooms.Clear();

        IEnumerable<RoomState> source = state.Rooms.Where(r => !state.HiddenRooms.Contains(r.Id));

        source = roomFilter switch
        {
            "unread" => source.Where(r => r.Unread > 0),
            "dm" => source.Where(r => !r.IsGroup),
            "groups" => source.Where(r => r.IsGroup && !r.IsChannel),
            "channels" => source.Where(r => r.IsChannel),
            "archive" => source.Where(r => r.Archived),
            _ => source.Where(r => !r.Archived)
        };

        source = source.Where(r =>
            string.IsNullOrWhiteSpace(query) ||
            r.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
            state.Messages.Any(m => m.RoomId == r.Id && m.Text.Contains(query, StringComparison.OrdinalIgnoreCase)));

        source = source.OrderByDescending(r => r.Pinned)
            .ThenByDescending(r => state.Messages.Where(m => m.RoomId == r.Id).Select(m => m.CreatedAt).DefaultIfEmpty(r.CreatedAt).Max());

        foreach (var room in source)
        {
            var last = state.Messages.Where(x => x.RoomId == room.Id).OrderBy(x => x.CreatedAt).LastOrDefault();
            var title = ResolveRoomTitle(room);
            rooms.Add(new RoomVm
            {
                Room = room,
                Title = title,
                Initial = string.IsNullOrWhiteSpace(title) ? "V" : title[..1].ToUpperInvariant(),
                Preview = room.Draft.Length > 0 ? "Черновик: " + room.Draft :
                    last?.Attachment != null && string.IsNullOrWhiteSpace(last.Text) ? last.Attachment.Name :
                    last?.Text ?? "Начни разговор",
                Time = last == null ? "" : DateTimeOffset.FromUnixTimeSeconds(last.CreatedAt).LocalDateTime.ToString("HH:mm"),
                Unread = room.Unread,
                Badge = room.IsChannel ? "CH" : room.IsGroup ? "GRP" : room.Muted ? "MUTE" : room.Pinned ? "PIN" : ""
            });
        }

        EmptyRooms.Visibility = rooms.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        if (previous != null)
        {
            var vm = rooms.FirstOrDefault(x => x.Room.Id == previous);
            if (vm != null) RoomList.SelectedItem = vm;
        }
        else if (rooms.Count > 0 && selectedRoom == null)
        {
            RoomList.SelectedIndex = 0;
        }
    }

    private void RefreshPeople()
    {
        var q = PeopleSearchBox?.Text?.Trim() ?? "";
        people.Clear();

        IEnumerable<ContactState> source = state.Contacts;
        source = peopleFilter switch
        {
            "favorite" => source.Where(x => x.Favorite),
            "verified" => source.Where(x => x.Verified),
            "blocked" => source.Where(x => x.Blocked),
            _ => source
        };
        source = source.Where(x => string.IsNullOrWhiteSpace(q) ||
            x.Name.Contains(q, StringComparison.OrdinalIgnoreCase) ||
            x.Card.Id.Contains(q, StringComparison.OrdinalIgnoreCase));
        source = source.OrderByDescending(x => x.Favorite).ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase);

        foreach (var contact in source)
        {
            var baseTitle = string.IsNullOrWhiteSpace(contact.Name) ? "Ghost " + contact.Card.Id[..6].ToUpperInvariant() : contact.Name;
            var title = string.IsNullOrWhiteSpace(contact.Alias) ? baseTitle : contact.Alias;
            var flags = new List<string>();
            if (contact.Favorite) flags.Add("★");
            if (contact.Verified) flags.Add("VERIFIED");
            if (contact.Blocked) flags.Add("BLOCKED");
            people.Add(new PersonVm
            {
                Contact = contact,
                Title = title,
                Initial = title[..1].ToUpperInvariant(),
                Fingerprint = contact.Card.Id[..Math.Min(20, contact.Card.Id.Length)].ToUpperInvariant() + "…",
                Flags = string.Join(" · ", flags)
            });
        }
    }

    private void RefreshTools()
    {
        if (DraftCount == null) return;
        var drafts = state.Rooms.Count(x => !string.IsNullOrWhiteSpace(x.Draft));
        var scheduled = state.Messages.Count(x => x.State == "scheduled");
        var bookmarks = state.Messages.Count(x => x.Bookmarked);
        var bytes = state.Messages.Sum(m => m.Text.Length * 2L + (m.Attachment?.Data.LongLength ?? 0));

        DraftCount.Text = drafts.ToString();
        ScheduledCount.Text = scheduled.ToString();
        BookmarkCount.Text = bookmarks.ToString();
        StorageCount.Text = bytes < 1024 * 1024 ? $"{Math.Max(1, bytes / 1024)} KB" : $"{bytes / 1024d / 1024d:F1} MB";

        toolsItems.Clear();
        foreach (var room in state.Rooms.Where(x => !string.IsNullOrWhiteSpace(x.Draft)))
            toolsItems.Add(new ToolsItemVm { Title = "Черновик · " + ResolveRoomTitle(room), Detail = room.Draft, Meta = "DRAFT" });
        foreach (var m in state.Messages.Where(x => x.State == "scheduled").OrderBy(x => x.ScheduledAt))
            toolsItems.Add(new ToolsItemVm { Title = "Отложено · " + ResolveRoomTitle(state.Rooms.FirstOrDefault(r => r.Id == m.RoomId)), Detail = m.Text, Meta = FormatWhen(m.ScheduledAt) });
        foreach (var m in state.Messages.Where(x => x.Bookmarked).OrderByDescending(x => x.CreatedAt))
            toolsItems.Add(new ToolsItemVm { Title = "Закладка · " + ResolveRoomTitle(state.Rooms.FirstOrDefault(r => r.Id == m.RoomId)), Detail = m.Text, Meta = DateTimeOffset.FromUnixTimeSeconds(m.CreatedAt).LocalDateTime.ToString("dd.MM HH:mm") });
    }

    private static string FormatWhen(long? sec) =>
        sec.HasValue ? DateTimeOffset.FromUnixTimeSeconds(sec.Value).LocalDateTime.ToString("dd.MM HH:mm") : "";

    private string ResolveRoomTitle(RoomState? room)
    {
        if (room == null) return "VO1D";
        if (!string.IsNullOrWhiteSpace(room.Title)) return room.Title;
        if (!room.IsGroup)
        {
            var peer = room.MemberIds.FirstOrDefault(id => id != crypto.Card.Id);
            var c = state.Contacts.FirstOrDefault(x => x.Card.Id == peer);
            if (c != null) return string.IsNullOrWhiteSpace(c.Alias) ? c.Name : c.Alias;
        }
        return room.IsChannel ? "Канал" : room.IsGroup ? "Группа" : "Разговор";
    }

    private ContactState? PeerFor(RoomState room)
    {
        if (room.IsGroup) return null;
        var id = room.MemberIds.FirstOrDefault(x => x != crypto.Card.Id);
        return state.Contacts.FirstOrDefault(x => x.Card.Id == id);
    }

    private void RenderSelected()
    {
        visibleMessages.Clear();

        if (selectedRoom == null)
        {
            NoChat.Visibility = Visibility.Visible;
            ComposerBox.IsEnabled = false;
            AttachButton.IsEnabled = false;
            VoiceButton.IsEnabled = false;
            SendButton.IsEnabled = false;
            ChatTitle.Text = "VO1D Desktop";
            ChatInitial.Text = "V";
            ChatSubtitle.Text = "E2EE · PRIVATE CHANNEL";
            PinnedStrip.Visibility = Visibility.Collapsed;
            return;
        }

        NoChat.Visibility = Visibility.Collapsed;
        selected = PeerFor(selectedRoom);
        var canPost = !selectedRoom.OnlyAdminsCanPost || selectedRoom.Admins.Contains(crypto.Card.Id);
        ComposerBox.IsEnabled = canPost;
        AttachButton.IsEnabled = canPost;
        VoiceButton.IsEnabled = canPost;
        SendButton.IsEnabled = canPost;
        ChatTitle.Text = ResolveRoomTitle(selectedRoom);
        ChatInitial.Text = string.IsNullOrWhiteSpace(ChatTitle.Text) ? "V" : ChatTitle.Text[..1].ToUpperInvariant();
        ChatSubtitle.Text = IsSavedRoom(selectedRoom)
            ? "ЛОКАЛЬНО · ТОЛЬКО НА ЭТОМ УСТРОЙСТВЕ"
            : selectedRoom.IsChannel ? "VO1D CHANNEL"
            : selectedRoom.IsGroup ? $"{selectedRoom.MemberIds.Count} УЧАСТНИКОВ · E2EE"
            : "E2EE · PRIVATE CHANNEL";

        loadingComposer = true;
        ComposerBox.Text = selectedRoom.Draft;
        ComposerBox.CaretIndex = ComposerBox.Text.Length;
        loadingComposer = false;
        ComposerHint.Visibility = string.IsNullOrEmpty(ComposerBox.Text) ? Visibility.Visible : Visibility.Collapsed;

        var messages = state.Messages.Where(x => x.RoomId == selectedRoom.Id)
            .Where(x => !x.ExpiresAt.HasValue || x.ExpiresAt > DateTimeOffset.UtcNow.ToUnixTimeSeconds())
            .OrderBy(x => x.CreatedAt).ToList();

        foreach (var m in messages)
        {
            var reply = !string.IsNullOrWhiteSpace(m.ReplyTo)
                ? messages.FirstOrDefault(x => x.Id == m.ReplyTo)?.Text
                : null;
            var scale = state.RoomTextScale.TryGetValue(selectedRoom.Id, out var roomScale)
                ? roomScale : state.Preferences.TextScale;
            visibleMessages.Add(MessageVm.From(m, reply, scale));
        }

        var pinId = selectedRoom.PinnedMessageIds.LastOrDefault();
        var pinned = pinId == null ? null : state.Messages.FirstOrDefault(x => x.Id == pinId);
        PinnedStrip.Visibility = pinned != null ? Visibility.Visible : Visibility.Collapsed;
        PinnedText.Text = pinned?.Text ?? "";

        selectedRoom.Unread = 0;
        Save();
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
            if (card.Id == crypto.Card.Id) throw new InvalidOperationException("Это твой собственный ID.");

            var existing = state.Contacts.FirstOrDefault(c => c.Card.Id == card.Id);
            if (existing == null)
            {
                existing = new ContactState { Name = name, Card = card };
                state.Contacts.Add(existing);
            }

            var roomId = DmRoomId(card.Id);
            var room = state.Rooms.FirstOrDefault(x => x.Id == roomId);
            if (room == null)
            {
                room = new RoomState
                {
                    Id = roomId,
                    Title = existing.Name,
                    MemberIds = new List<string> { crypto.Card.Id, card.Id },
                    Creator = crypto.Card.Id,
                    CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
                };
                state.Rooms.Add(room);
            }

            selectedRoom = room;
            selected = existing;
            Save();
            CloseModal();
            RefreshAll();
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

    private async Task SendMessageAsync(bool silent = false, long? scheduledAt = null)
    {
        if (selectedRoom == null) return;

        var text = ComposerBox.Text.Trim();
        if (editingId != null)
        {
            var edit = state.Messages.FirstOrDefault(x => x.Id == editingId && x.Mine);
            if (edit == null || text.Length == 0) return;
            edit.EditHistory.Add(edit.Text);
            edit.Text = text;
            edit.Edited = true;
            selectedRoom.Draft = "";
            CancelComposerContext();
            Save();
            RefreshAll();
            await SendControlEventAsync("edit", edit.Id, text);
            return;
        }

        if (text.Length == 0 && pendingAttachment == null) return;

        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var message = new LocalMessage
        {
            Id = Guid.NewGuid().ToString(),
            RoomId = selectedRoom.Id,
            PeerId = selected?.Card.Id ?? "",
            SenderId = crypto.Card.Id,
            Mine = true,
            Text = text,
            CreatedAt = now,
            ExpiresAt = selectedRoom.DisappearingSeconds > 0 ? now + selectedRoom.DisappearingSeconds : null,
            ReplyTo = replyingToId,
            Attachment = pendingAttachment,
            State = scheduledAt.HasValue ? "scheduled" : "queued",
            ScheduledAt = scheduledAt,
            Silent = silent
        };

        state.Messages.Add(message);
        selectedRoom.Draft = "";
        ComposerBox.Clear();
        pendingAttachment = null;
        PendingAttachmentText.Visibility = Visibility.Collapsed;
        CancelComposerContext();
        Save();
        RefreshAll();
        AnimateSendButton();

        if (scheduledAt.HasValue)
        {
            Save();
            RefreshAll();
            ShowToast("СООБЩЕНИЕ ЗАПЛАНИРОВАНО");
            return;
        }

        if (IsSavedRoom(selectedRoom))
        {
            message.State = "sent";
            Save();
            RefreshAll();
            return;
        }

        try
        {
            await SendWireMessageAsync(message);
            message.State = "sent";
        }
        catch (Exception ex)
        {
            message.State = "failed";
            ShowToast(ex.Message);
        }

        Save();
        RefreshAll();
    }

    private async Task SendWireMessageAsync(LocalMessage local)
    {
        if (selectedRoom == null) return;
        var own = crypto.Card;
        var memberCards = selectedRoom.MemberIds.Select(id =>
        {
            if (id == own.Id) return own;
            return state.Contacts.FirstOrDefault(c => c.Card.Id == id)?.Card;
        }).Where(x => x != null).Cast<ContactCard>().ToArray();

        var room = new
        {
            id = selectedRoom.Id,
            title = ResolveRoomTitle(selectedRoom),
            members = memberCards,
            creator = selectedRoom.Creator,
            isGroup = selectedRoom.IsGroup,
            createdAt = selectedRoom.CreatedAt,
            pinned = selectedRoom.Pinned,
            archived = selectedRoom.Archived,
            muted = selectedRoom.Muted,
            unread = selectedRoom.Unread,
            draft = "",
            disappearingSeconds = selectedRoom.DisappearingSeconds,
            admins = selectedRoom.Admins.Count == 0 ? null : selectedRoom.Admins.ToArray(),
            onlyAdminsCanPost = selectedRoom.OnlyAdminsCanPost ? true : (bool?)null,
            pinnedMessageIDs = selectedRoom.PinnedMessageIds.Count == 0 ? null : selectedRoom.PinnedMessageIds.ToArray(),
            isChannel = selectedRoom.IsChannel ? true : (bool?)null,
            topics = selectedRoom.Topics.Count == 0 ? null : selectedRoom.Topics.ToArray(),
            mutedUntil = (long?)null,
            privateRoster = (bool?)null,
            membershipEpoch = (int?)null
        };

        object? attachment = local.Attachment == null ? null : new
        {
            name = local.Attachment.Name,
            mime = local.Attachment.Mime,
            data = local.Attachment.Data,
            viewSeconds = local.Attachment.ViewSeconds,
            voiceEffect = (string?)null,
            blobID = (string?)null,
            blobReadToken = (string?)null,
            blobKey = (string?)null,
            blobSize = (int?)null,
            blobDigest = (string?)null,
            blobExpiresAt = (long?)null,
            previewData = (byte[]?)null
        };

        var message = new
        {
            id = local.Id,
            roomID = selectedRoom.Id,
            sender = own.Id,
            text = local.Text,
            createdAt = local.CreatedAt,
            expiresAt = local.ExpiresAt,
            replyTo = local.ReplyTo,
            attachment,
            state = "sent",
            edited = local.Edited,
            reactions = local.Reactions,
            readBy = local.ReadBy,
            deliveredTo = local.DeliveredTo,
            openedAt = local.OpenedAt,
            forwardedFrom = local.ForwardedFrom,
            scheduledAt = local.ScheduledAt,
            silent = local.Silent ? true : (bool?)null,
            editHistory = local.EditHistory.Count == 0 ? null : local.EditHistory.ToArray(),
            poll = local.Poll,
            topic = local.Topic,
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
            at = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
        };

        var clear = JsonSerializer.SerializeToUtf8Bytes(ev, AppJson.Options);
        var targets = memberCards.Where(c => c.Id != own.Id).ToList();
        if (targets.Count == 0)
        {
            if (IsSavedRoom(selectedRoom)) return;
            throw new InvalidOperationException("В разговоре нет получателей.");
        }

        foreach (var target in targets)
        {
            var contact = state.Contacts.FirstOrDefault(x => x.Card.Id == target.Id);
            if (contact?.Blocked == true) continue;
            var envelope = await SealSignalAsync(clear, target);
            await api.SendEnvelopeAsync(envelope);
        }
    }

    private async Task SendControlEventAsync(string kind, string targetId, string? value)
    {
        if (selectedRoom == null) return;
        var own = crypto.Card;
        var cards = selectedRoom.MemberIds.Select(id => id == own.Id ? own : state.Contacts.FirstOrDefault(c => c.Card.Id == id)?.Card)
            .Where(x => x != null).Cast<ContactCard>().ToArray();

        var room = new
        {
            id = selectedRoom.Id,
            title = ResolveRoomTitle(selectedRoom),
            members = cards,
            creator = selectedRoom.Creator,
            isGroup = selectedRoom.IsGroup,
            createdAt = selectedRoom.CreatedAt,
            pinned = selectedRoom.Pinned,
            archived = selectedRoom.Archived,
            muted = selectedRoom.Muted,
            unread = selectedRoom.Unread,
            draft = "",
            disappearingSeconds = selectedRoom.DisappearingSeconds,
            admins = selectedRoom.Admins.Count == 0 ? null : selectedRoom.Admins.ToArray(),
            onlyAdminsCanPost = selectedRoom.OnlyAdminsCanPost ? true : (bool?)null,
            pinnedMessageIDs = selectedRoom.PinnedMessageIds.Count == 0 ? null : selectedRoom.PinnedMessageIds.ToArray(),
            isChannel = selectedRoom.IsChannel ? true : (bool?)null,
            topics = selectedRoom.Topics.Count == 0 ? null : selectedRoom.Topics.ToArray(),
            mutedUntil = (long?)null,
            privateRoster = (bool?)null,
            membershipEpoch = (int?)null
        };

        var ev = new
        {
            deviceCertificate = (object?)null,
            historyArchive = (object?)null,
            groupInvitation = (object?)null,
            replyMailbox = (object?)null,
            id = Guid.NewGuid().ToString(),
            kind,
            room,
            message = (object?)null,
            target = targetId,
            value,
            senderName = state.Nickname,
            padding = (string?)null,
            at = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
        };

        var clear = JsonSerializer.SerializeToUtf8Bytes(ev, AppJson.Options);
        foreach (var target in cards.Where(c => c.Id != own.Id))
        {
            var envelope = await SealSignalAsync(clear, target);
            await api.SendEnvelopeAsync(envelope);
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
                        contact = new ContactState { Name = "Ghost " + sender.Id[..6].ToUpperInvariant(), Card = sender };
                        state.Contacts.Add(contact);
                    }

                    var outerClear = crypto.Open(env, sender);
                    byte[] eventClear = outerClear;

                    using (var outerDoc = JsonDocument.Parse(outerClear))
                    {
                        var outerRoot = outerDoc.RootElement;
                        if (outerRoot.TryGetProperty("version", out var version) &&
                            version.ValueKind == JsonValueKind.Number &&
                            version.GetInt32() == 2 &&
                            outerRoot.TryGetProperty("ciphertext", out _))
                        {
                            if (signal == null) throw new InvalidOperationException("Signal runtime не запущен.");
                            state.SignalSnapshotJson ??= await signal.CreateSnapshotAsync();

                            var packet = JsonSerializer.Deserialize<SignalPacketDto>(
                                outerRoot.GetRawText(), AppJson.Options)
                                ?? throw new InvalidDataException("Повреждённый SignalPacket.");

                            IdentityCrypto.ValidateSignalPacket(packet, sender);
                            var decrypted = await signal.DecryptAsync(state.SignalSnapshotJson, sender.Id, packet);
                            state.SignalSnapshotJson = decrypted.SnapshotJson;
                            eventClear = decrypted.Clear;
                            ProtocolStatus.Text = "Signal v2 · PQXDH + Double Ratchet · libsignal 0.70.0";
                            QueueText.Text = "SIGNAL V2";
                        }
                    }

                    using var doc = JsonDocument.Parse(eventClear);
                    ApplyIncomingEvent(doc.RootElement, sender);
                    state.Processed.Add(env.Id);
                    ack.Add(env.Id);
                }
                catch
                {
                    // Invalid/decryption failures remain unacknowledged.
                }
            }

            if (ack.Count > 0) await api.AckAsync(ack);
            Save();
            ConnectionText.Text = "ПОДКЛЮЧЁН";
            if (QueueText.Text != "SIGNAL V2") QueueText.Text = "E2EE";
            RefreshAll();
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

    private void ApplyIncomingEvent(JsonElement root, ContactCard sender)
    {
        if (!root.TryGetProperty("kind", out var kindEl)) return;
        var kind = kindEl.GetString() ?? "";

        RoomState? room = null;
        if (root.TryGetProperty("room", out var roomEl) && roomEl.ValueKind == JsonValueKind.Object)
            room = UpsertRoomFromWire(roomEl, sender);

        var target = root.TryGetProperty("target", out var targetEl) && targetEl.ValueKind == JsonValueKind.String ? targetEl.GetString() : null;
        var value = root.TryGetProperty("value", out var valueEl) && valueEl.ValueKind == JsonValueKind.String ? valueEl.GetString() : null;

        if (HandleParityIncoming(kind, room, target, value, sender)) return;

        if (kind == "message" && room != null && root.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.Object)
        {
            var id = GetString(m, "id") ?? Guid.NewGuid().ToString();
            if (state.Messages.Any(x => x.Id == id)) return;

            var body = GetString(m, "text") ?? "";
            var at = GetInt64(m, "createdAt") ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var attachment = ParseAttachment(m);
            var reactions = ParseStringDictionary(m, "reactions");

            state.Messages.Add(new LocalMessage
            {
                Id = id,
                RoomId = room.Id,
                PeerId = sender.Id,
                SenderId = sender.Id,
                Mine = false,
                Text = body,
                CreatedAt = at,
                ReplyTo = GetString(m, "replyTo"),
                Attachment = attachment,
                Edited = GetBool(m, "edited"),
                Reactions = reactions,
                ReadBy = ParseStringArray(m, "readBy"),
                DeliveredTo = ParseStringArray(m, "deliveredTo"),
                OpenedAt = GetInt64(m, "openedAt"),
                ForwardedFrom = GetString(m, "forwardedFrom"),
                Poll = ParsePoll(m),
                Topic = GetString(m, "topic"),
                ExpiresAt = GetInt64(m, "expiresAt"),
                State = "sent"
            });

            if (selectedRoom?.Id != room.Id) room.Unread++;
        }
        else if (target != null)
        {
            var msg = state.Messages.FirstOrDefault(x => x.Id == target);
            if (msg == null) return;
            if (kind == "edit" && value != null)
            {
                msg.EditHistory.Add(msg.Text);
                msg.Text = value;
                msg.Edited = true;
            }
            else if (kind == "delete")
            {
                state.Messages.Remove(msg);
            }
            else if (kind == "reaction" && value != null)
            {
                msg.Reactions[sender.Id] = value;
            }
        }
    }

    private RoomState UpsertRoomFromWire(JsonElement el, ContactCard sender)
    {
        var id = GetString(el, "id") ?? DmRoomId(sender.Id);
        var room = state.Rooms.FirstOrDefault(x => x.Id == id);
        if (room == null)
        {
            room = new RoomState { Id = id, CreatedAt = GetInt64(el, "createdAt") ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds() };
            state.Rooms.Add(room);
        }
        room.Title = GetString(el, "title") ?? room.Title;
        room.Creator = GetString(el, "creator") ?? room.Creator;
        room.IsGroup = GetBool(el, "isGroup");
        room.IsChannel = GetBool(el, "isChannel");
        room.OnlyAdminsCanPost = GetBool(el, "onlyAdminsCanPost");
        room.DisappearingSeconds = (int)(GetInt64(el, "disappearingSeconds") ?? room.DisappearingSeconds);

        if (el.TryGetProperty("members", out var members) && members.ValueKind == JsonValueKind.Array)
        {
            room.MemberIds.Clear();
            foreach (var item in members.EnumerateArray())
            {
                var mid = GetString(item, "id");
                if (mid != null) room.MemberIds.Add(mid);
            }
        }
        if (!room.MemberIds.Contains(crypto.Card.Id)) room.MemberIds.Add(crypto.Card.Id);
        if (!room.MemberIds.Contains(sender.Id)) room.MemberIds.Add(sender.Id);
        return room;
    }

    private static AttachmentState? ParseAttachment(JsonElement message)
    {
        if (!message.TryGetProperty("attachment", out var a) || a.ValueKind != JsonValueKind.Object) return null;
        byte[] data = Array.Empty<byte>();
        if (a.TryGetProperty("data", out var d) && d.ValueKind == JsonValueKind.String)
        {
            try { data = Convert.FromBase64String(d.GetString() ?? ""); } catch { }
        }
        return new AttachmentState
        {
            Name = GetString(a, "name") ?? "Вложение",
            Mime = GetString(a, "mime") ?? "application/octet-stream",
            Data = data,
            ViewSeconds = (int?)GetInt64(a, "viewSeconds")
        };
    }

    private static List<string> ParseStringArray(JsonElement parent, string name)
    {
        var result = new List<string>();
        if (!parent.TryGetProperty(name, out var el) || el.ValueKind != JsonValueKind.Array) return result;
        foreach (var item in el.EnumerateArray())
            if (item.ValueKind == JsonValueKind.String && item.GetString() is { Length: > 0 } text) result.Add(text);
        return result;
    }

    private static PollState? ParsePoll(JsonElement message)
    {
        if (!message.TryGetProperty("poll", out var p) || p.ValueKind != JsonValueKind.Object) return null;
        var poll = new PollState
        {
            Question = GetString(p, "question") ?? "",
            Closed = GetBool(p, "closed")
        };
        if (p.TryGetProperty("privateVotes", out var pv) && (pv.ValueKind == JsonValueKind.True || pv.ValueKind == JsonValueKind.False))
            poll.PrivateVotes = pv.GetBoolean();
        if (p.TryGetProperty("privateCounts", out var pc) && pc.ValueKind == JsonValueKind.Object)
        {
            poll.PrivateCounts = new Dictionary<string, int>();
            foreach (var item in pc.EnumerateObject())
                if (item.Value.ValueKind == JsonValueKind.Number && item.Value.TryGetInt32(out var count))
                    poll.PrivateCounts[item.Name] = count;
        }
        if (p.TryGetProperty("options", out var options) && options.ValueKind == JsonValueKind.Array)
        {
            foreach (var option in options.EnumerateArray())
            {
                poll.Options.Add(new PollOptionState
                {
                    Id = GetString(option, "id") ?? Guid.NewGuid().ToString(),
                    Text = GetString(option, "text") ?? "",
                    VoterIDs = ParseStringArray(option, "voterIDs")
                });
            }
        }
        return poll;
    }

    private static Dictionary<string, string> ParseStringDictionary(JsonElement parent, string name)
    {
        var result = new Dictionary<string, string>();
        if (!parent.TryGetProperty(name, out var el) || el.ValueKind != JsonValueKind.Object) return result;
        foreach (var p in el.EnumerateObject())
            if (p.Value.ValueKind == JsonValueKind.String) result[p.Name] = p.Value.GetString() ?? "";
        return result;
    }

    private static string? GetString(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    private static long? GetInt64(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n) ? n : null;
    private static bool GetBool(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && (v.ValueKind == JsonValueKind.True || v.ValueKind == JsonValueKind.False) && v.GetBoolean();

    private async Task FlushScheduledAsync()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var due = state.Messages.Where(x => x.State == "scheduled" && x.ScheduledAt <= now).ToList();
        foreach (var message in due)
        {
            var oldRoom = selectedRoom;
            selectedRoom = state.Rooms.FirstOrDefault(x => x.Id == message.RoomId);
            try
            {
                if (!IsSavedRoom(selectedRoom))
                    await SendWireMessageAsync(message);
                message.State = "sent";
            }
            catch { message.State = "failed"; }
            selectedRoom = oldRoom;
        }
        if (due.Count > 0) { Save(); RefreshAll(); }
    }

    private void AnimateSendButton()
    {
        var transform = SendButton.RenderTransform as ScaleTransform ?? new ScaleTransform(1, 1);
        SendButton.RenderTransform = transform;
        SendButton.RenderTransformOrigin = new Point(.5, .5);
        var anim = new DoubleAnimation(.86, 1, TimeSpan.FromMilliseconds(260))
        { EasingFunction = new BackEase { Amplitude = .35, EasingMode = EasingMode.EaseOut } };
        transform.BeginAnimation(ScaleTransform.ScaleXProperty, anim);
        transform.BeginAnimation(ScaleTransform.ScaleYProperty, anim);
    }

    private void SetNav(string workspace)
    {
        activeWorkspace = workspace;
        ChatWorkspace.Visibility = workspace == "chats" ? Visibility.Visible : Visibility.Collapsed;
        PeopleWorkspace.Visibility = workspace == "people" ? Visibility.Visible : Visibility.Collapsed;
        ToolsWorkspace.Visibility = workspace == "tools" ? Visibility.Visible : Visibility.Collapsed;
        SettingsWorkspace.Visibility = workspace == "settings" ? Visibility.Visible : Visibility.Collapsed;
        RoomsPane.Visibility = workspace == "chats" ? Visibility.Visible : Visibility.Collapsed;

        ChatsNav.Background = BrushFor(workspace == "chats");
        PeopleNav.Background = BrushFor(workspace == "people");
        ToolsNav.Background = BrushFor(workspace == "tools");
        SettingsNav.Background = BrushFor(workspace == "settings");

        var target = workspace switch
        {
            "chats" => (UIElement)ChatWorkspace,
            "people" => PeopleWorkspace,
            "tools" => ToolsWorkspace,
            _ => SettingsWorkspace
        };
        target.Opacity = 0;
        target.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(220))
            { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });

        if (workspace == "tools") RefreshTools();
    }

    private static Brush BrushFor(bool active) =>
        new SolidColorBrush(active ? Color.FromArgb(30, 255, 255, 255) : Colors.Transparent);

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
            new DoubleAnimation(.96, 1, TimeSpan.FromMilliseconds(260)) { EasingFunction = new BackEase { Amplitude = .18, EasingMode = EasingMode.EaseOut } });
        AddCardScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(.96, 1, TimeSpan.FromMilliseconds(260)) { EasingFunction = new BackEase { Amplitude = .18, EasingMode = EasingMode.EaseOut } });
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

    private void OpenCompose()
    {
        RefreshPeople();
        ComposePeopleList.SelectedItems.Clear();
        ComposeType.SelectedIndex = 0;
        ComposeTitleBox.Clear();
        ComposeLayer.Visibility = Visibility.Visible;
        ComposeLayer.Opacity = 0;
        ComposeLayer.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
    }

    private void CloseCompose()
    {
        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(140));
        fade.Completed += (_, _) => ComposeLayer.Visibility = Visibility.Collapsed;
        ComposeLayer.BeginAnimation(OpacityProperty, fade);
    }

    private void CancelComposerContext()
    {
        replyingToId = null;
        editingId = null;
        ComposerContext.Visibility = Visibility.Collapsed;
        ComposerContextTitle.Text = "";
        ComposerContextPreview.Text = "";
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) ToggleMaximize();
        else DragMove();
    }

    private void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void Maximize_Click(object sender, RoutedEventArgs e) => ToggleMaximize();
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void ToggleMaximize() => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private void ChatsNav_Click(object sender, RoutedEventArgs e) => SetNav("chats");
    private void PeopleNav_Click(object sender, RoutedEventArgs e) => SetNav("people");
    private void ToolsNav_Click(object sender, RoutedEventArgs e) => SetNav("tools");
    private void SettingsNav_Click(object sender, RoutedEventArgs e) => SetNav("settings");

    private void OpenAddContact_Click(object sender, RoutedEventArgs e) => OpenModal();
    private void OpenCompose_Click(object sender, RoutedEventArgs e) => OpenCompose();
    private void CloseModal_Click(object sender, RoutedEventArgs e) => CloseModal();
    private void ModalLayer_MouseDown(object sender, MouseButtonEventArgs e) => CloseModal();
    private void AddCard_MouseDown(object sender, MouseButtonEventArgs e) => e.Handled = true;
    private void ComposeLayer_MouseDown(object sender, MouseButtonEventArgs e) => CloseCompose();
    private void ComposeCard_MouseDown(object sender, MouseButtonEventArgs e) => e.Handled = true;
    private void CloseCompose_Click(object sender, RoutedEventArgs e) => CloseCompose();

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (SearchHint != null) SearchHint.Visibility = string.IsNullOrEmpty(SearchBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        if (crypto != null) RefreshCollections();
    }

    private void PeopleSearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (PeopleSearchHint != null) PeopleSearchHint.Visibility = string.IsNullOrEmpty(PeopleSearchBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        if (crypto != null) RefreshPeople();
    }

    private void ComposerBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (ComposerHint != null) ComposerHint.Visibility = string.IsNullOrEmpty(ComposerBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        if (loadingComposer || selectedRoom == null) return;
        selectedRoom.Draft = ComposerBox.Text;
        Save();
        RefreshTools();
        _ = SendTypingPulseAsync();
    }

    private void Filter_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button b && b.Tag is string tag)
        {
            roomFilter = tag;
            RefreshCollections();
        }
    }

    private void PeopleFilter_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button b && b.Tag is string tag)
        {
            peopleFilter = tag;
            RefreshPeople();
        }
    }

    private void RoomList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (RoomList.SelectedItem is not RoomVm vm) return;
        selectedRoom = vm.Room;
        selected = PeerFor(selectedRoom);
        RenderSelected();
        _ = MarkSelectedRoomReadAsync();
    }

    private void OpenPersonChat_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.CommandParameter is not PersonVm vm) return;
        var id = DmRoomId(vm.Contact.Card.Id);
        selectedRoom = state.Rooms.FirstOrDefault(x => x.Id == id);
        if (selectedRoom == null)
        {
            selectedRoom = new RoomState
            {
                Id = id,
                Title = vm.Contact.Name,
                MemberIds = new List<string> { crypto.Card.Id, vm.Contact.Card.Id },
                Creator = crypto.Card.Id,
                CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
            };
            state.Rooms.Add(selectedRoom);
            Save();
        }
        SetNav("chats");
        RefreshAll();
    }

    private async void Send_Click(object sender, RoutedEventArgs e) => await SendMessageAsync();

    private async void SendSilent_Click(object sender, RoutedEventArgs e) =>
        await SendMessageAsync(silent: true);

    private async void SendInMinute_Click(object sender, RoutedEventArgs e) =>
        await SendMessageAsync(scheduledAt: DateTimeOffset.UtcNow.AddMinutes(1).ToUnixTimeSeconds());

    private async void SendInTenMinutes_Click(object sender, RoutedEventArgs e) =>
        await SendMessageAsync(scheduledAt: DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds());

    private async void SendInHour_Click(object sender, RoutedEventArgs e) =>
        await SendMessageAsync(scheduledAt: DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds());

    private void OpenSaved_Click(object sender, RoutedEventArgs e)
    {
        selectedRoom = state.Rooms.FirstOrDefault(r => r.Id == SavedRoomId);
        selected = null;
        SetNav("chats");
        RefreshAll();
        ComposerBox.Focus();
        Keyboard.Focus(ComposerBox);
    }

    private async void ComposerBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Keyboard.Modifiers != ModifierKeys.Shift)
        {
            e.Handled = true;
            await SendMessageAsync();
        }
    }

    private void Attach_Click(object sender, RoutedEventArgs e)
    {
        if (selectedRoom == null) return;
        var dialog = new OpenFileDialog { Title = "Добавить вложение", Multiselect = false };
        if (dialog.ShowDialog(this) != true) return;

        var info = new FileInfo(dialog.FileName);
        var max = Math.Clamp(state.Preferences.FileLimitMb, 1, 50) * 1024L * 1024L;
        if (info.Length > max)
        {
            ShowToast($"Файл больше лимита {state.Preferences.FileLimitMb} МБ");
            return;
        }

        pendingAttachment = new AttachmentState
        {
            Name = info.Name,
            Mime = GuessMime(info.Extension),
            Data = File.ReadAllBytes(info.FullName)
        };
        PendingAttachmentText.Text = "Вложение · " + info.Name;
        PendingAttachmentText.Visibility = Visibility.Visible;
    }

    private static string GuessMime(string ext) => ext.ToLowerInvariant() switch
    {
        ".png" => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".webp" => "image/webp",
        ".gif" => "image/gif",
        ".pdf" => "application/pdf",
        ".txt" => "text/plain",
        ".json" => "application/json",
        ".wav" => "audio/wav",
        ".mp3" => "audio/mpeg",
        ".m4a" => "audio/mp4",
        _ => "application/octet-stream"
    };

    private void CancelComposerContext_Click(object sender, RoutedEventArgs e) => CancelComposerContext();

    private MessageVm? MessageFrom(object sender) => (sender as MenuItem)?.CommandParameter as MessageVm;
    private RoomVm? RoomFrom(object sender) => (sender as MenuItem)?.CommandParameter as RoomVm;
    private PersonVm? PersonFrom(object sender) => (sender as MenuItem)?.CommandParameter as PersonVm;

    private void MessageReply_Click(object sender, RoutedEventArgs e)
    {
        var vm = MessageFrom(sender); if (vm == null) return;
        replyingToId = vm.Source.Id; editingId = null;
        ComposerContextTitle.Text = "Ответ";
        ComposerContextPreview.Text = vm.Source.Text;
        ComposerContext.Visibility = Visibility.Visible;
        ComposerBox.Focus();
    }

    private void MessageEdit_Click(object sender, RoutedEventArgs e)
    {
        var vm = MessageFrom(sender); if (vm == null || !vm.Source.Mine) return;
        editingId = vm.Source.Id; replyingToId = null;
        ComposerContextTitle.Text = "Редактирование";
        ComposerContextPreview.Text = vm.Source.Text;
        ComposerContext.Visibility = Visibility.Visible;
        loadingComposer = true;
        ComposerBox.Text = vm.Source.Text;
        ComposerBox.CaretIndex = ComposerBox.Text.Length;
        loadingComposer = false;
        ComposerBox.Focus();
    }

    private void MessageCopy_Click(object sender, RoutedEventArgs e)
    {
        var vm = MessageFrom(sender); if (vm == null || string.IsNullOrEmpty(vm.Source.Text)) return;
        Clipboard.SetText(vm.Source.Text);
        ShowToast("СКОПИРОВАНО");
    }

    private async void MessageReact_Click(object sender, RoutedEventArgs e)
    {
        var vm = MessageFrom(sender); if (vm == null) return;
        vm.Source.Reactions[crypto.Card.Id] = "❤️";
        Save(); RefreshAll();
        try { await SendControlEventAsync("reaction", vm.Source.Id, "❤️"); } catch { }
    }

    private void MessageBookmark_Click(object sender, RoutedEventArgs e)
    {
        var vm = MessageFrom(sender); if (vm == null) return;
        vm.Source.Bookmarked = !vm.Source.Bookmarked;
        Save(); RefreshAll();
    }

    private void MessagePin_Click(object sender, RoutedEventArgs e)
    {
        var vm = MessageFrom(sender); if (vm == null || selectedRoom == null) return;
        if (selectedRoom.PinnedMessageIds.Contains(vm.Source.Id)) selectedRoom.PinnedMessageIds.Remove(vm.Source.Id);
        else selectedRoom.PinnedMessageIds.Add(vm.Source.Id);
        Save(); RefreshAll();
    }

    private async void MessageDelete_Click(object sender, RoutedEventArgs e)
    {
        var vm = MessageFrom(sender); if (vm == null) return;
        var id = vm.Source.Id;
        state.Messages.Remove(vm.Source);
        Save(); RefreshAll();
        if (vm.Source.Mine)
        {
            try { await SendControlEventAsync("delete", id, null); } catch { }
        }
    }

    private void UnpinMessage_Click(object sender, RoutedEventArgs e)
    {
        if (selectedRoom == null || selectedRoom.PinnedMessageIds.Count == 0) return;
        selectedRoom.PinnedMessageIds.RemoveAt(selectedRoom.PinnedMessageIds.Count - 1);
        Save(); RefreshAll();
    }

    private void RoomPin_Click(object sender, RoutedEventArgs e)
    {
        var vm = RoomFrom(sender); if (vm == null) return;
        vm.Room.Pinned = !vm.Room.Pinned; Save(); RefreshCollections();
    }

    private void RoomArchive_Click(object sender, RoutedEventArgs e)
    {
        var vm = RoomFrom(sender); if (vm == null) return;
        vm.Room.Archived = !vm.Room.Archived; Save(); RefreshCollections();
    }

    private void RoomMute_Click(object sender, RoutedEventArgs e)
    {
        var vm = RoomFrom(sender); if (vm == null) return;
        vm.Room.Muted = !vm.Room.Muted; Save(); RefreshCollections();
    }

    private void RoomHide_Click(object sender, RoutedEventArgs e)
    {
        var vm = RoomFrom(sender); if (vm == null) return;
        state.HiddenRooms.Add(vm.Room.Id);
        if (selectedRoom?.Id == vm.Room.Id) { selectedRoom = null; selected = null; }
        Save(); RefreshAll();
    }

    private void ContactFavorite_Click(object sender, RoutedEventArgs e)
    {
        var vm = PersonFrom(sender); if (vm == null) return;
        vm.Contact.Favorite = !vm.Contact.Favorite; Save(); RefreshPeople();
    }

    private void ContactVerify_Click(object sender, RoutedEventArgs e)
    {
        var vm = PersonFrom(sender); if (vm == null) return;
        vm.Contact.Verified = !vm.Contact.Verified; Save(); RefreshPeople();
    }

    private async void ContactBlock_Click(object sender, RoutedEventArgs e)
    {
        var vm = PersonFrom(sender); if (vm == null) return;
        vm.Contact.Blocked = !vm.Contact.Blocked;
        Save(); RefreshPeople();
        try { await api.SetBlockedAsync(vm.Contact.Card.Id, vm.Contact.Blocked); }
        catch (Exception ex) { ShowToast(ex.Message); }
    }

    private void FocusChatSearch_Click(object sender, RoutedEventArgs e)
    {
        SearchBox.Focus();
        Keyboard.Focus(SearchBox);
    }

    private void OpenRoomInfo_Click(object sender, RoutedEventArgs e)
    {
        if (selectedRoom == null) return;
        ShowToast($"{ResolveRoomTitle(selectedRoom)} · {selectedRoom.MemberIds.Count} участников · {state.Messages.Count(x => x.RoomId == selectedRoom.Id)} сообщений");
    }

    private async void RotateCode_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            state.PublicCode = await api.RotateCodeAsync();
            Save();
            ApplySettingsToUi();
            ShowToast("VO1D ID ОБНОВЛЁН");
        }
        catch (Exception ex) { ShowToast(ex.Message); }
    }

    private void Preference_Click(object sender, RoutedEventArgs e)
    {
        state.Preferences.CompactRows = CompactRowsToggle.IsChecked == true;
        state.Preferences.HideMedia = HideMediaToggle.IsChecked == true;
        state.Preferences.ProtectCapture = ProtectCaptureToggle.IsChecked == true;
        state.Preferences.LowData = LowDataToggle.IsChecked == true;
        state.Preferences.ConfirmLinks = ConfirmLinksToggle.IsChecked == true;
        state.Preferences.CleanLinks = CleanLinksToggle.IsChecked == true;
        state.Preferences.QuietHours = QuietHoursToggle.IsChecked == true;
        poll.Interval = state.Preferences.LowData ? TimeSpan.FromSeconds(8) : TimeSpan.FromSeconds(3.5);
        Save();
        RefreshAll();
    }

    private void CreateRoom_Click(object sender, RoutedEventArgs e)
    {
        var selectedPeople = ComposePeopleList.SelectedItems.Cast<PersonVm>().Select(x => x.Contact).ToList();
        var type = ComposeType.SelectedIndex;

        if (type == 0)
        {
            if (selectedPeople.Count != 1) { ShowToast("ВЫБЕРИ ОДНОГО ЧЕЛОВЕКА"); return; }
            var contact = selectedPeople[0];
            var id = DmRoomId(contact.Card.Id);
            selectedRoom = state.Rooms.FirstOrDefault(x => x.Id == id) ?? new RoomState
            {
                Id = id,
                Title = contact.Name,
                MemberIds = new List<string> { crypto.Card.Id, contact.Card.Id },
                Creator = crypto.Card.Id,
                CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
            };
            if (state.Rooms.All(x => x.Id != id)) state.Rooms.Add(selectedRoom);
        }
        else
        {
            var title = ComposeTitleBox.Text.Trim();
            if (title.Length == 0) { ShowToast("НУЖНО НАЗВАНИЕ"); return; }
            if (selectedPeople.Count == 0 && type == 1) { ShowToast("ДОБАВЬ УЧАСТНИКА"); return; }
            selectedRoom = new RoomState
            {
                Id = "room:" + Guid.NewGuid().ToString("N"),
                Title = title.Length > 48 ? title[..48] : title,
                MemberIds = new List<string> { crypto.Card.Id }.Concat(selectedPeople.Select(x => x.Card.Id)).Distinct().ToList(),
                Creator = crypto.Card.Id,
                IsGroup = true,
                IsChannel = type == 2,
                OnlyAdminsCanPost = type == 2,
                Admins = new List<string> { crypto.Card.Id },
                CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
            };
            state.Rooms.Add(selectedRoom);
        }

        Save();
        CloseCompose();
        SetNav("chats");
        RefreshAll();
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
    public RoomState Room { get; set; } = new();
    public string Title { get; set; } = "";
    public string Initial { get; set; } = "";
    public string Preview { get; set; } = "";
    public string Time { get; set; } = "";
    public string Badge { get; set; } = "";
    public int Unread { get; set; }
    public Visibility UnreadVisibility => Unread > 0 ? Visibility.Visible : Visibility.Collapsed;
}

internal sealed class PersonVm
{
    public ContactState Contact { get; set; } = new();
    public string Title { get; set; } = "";
    public string Initial { get; set; } = "";
    public string Fingerprint { get; set; } = "";
    public string Flags { get; set; } = "";
}

internal sealed partial class MessageVm
{
    public LocalMessage Source { get; set; } = new();
    public string Text => Source.Text;
    public string Time { get; set; } = "";
    public HorizontalAlignment Align => Source.Mine ? HorizontalAlignment.Right : HorizontalAlignment.Left;
    public Brush BubbleBrush => new SolidColorBrush(Source.Mine ? Color.FromRgb(226, 226, 234) : Color.FromRgb(21, 21, 21));
    public Brush ForegroundBrush => new SolidColorBrush(Source.Mine ? Colors.Black : Colors.White);
    public Brush MetaBrush => new SolidColorBrush(Source.Mine ? Color.FromArgb(150, 0, 0, 0) : Color.FromArgb(120, 255, 255, 255));
    public double FontSize { get; set; } = 14.5;
    public string ReplyPreview { get; set; } = "";
    public Visibility ReplyVisibility => string.IsNullOrWhiteSpace(ReplyPreview) ? Visibility.Collapsed : Visibility.Visible;
    public string AttachmentName => Source.Attachment?.Name ?? "";
    public Visibility AttachmentVisibility => Source.Attachment == null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility ImageVisibility => Source.Attachment?.Mime.StartsWith("image/", StringComparison.OrdinalIgnoreCase) == true &&
                                         Source.Attachment.Data.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public ImageSource? ImagePreview
    {
        get
        {
            if (ImageVisibility != Visibility.Visible || Source.Attachment == null) return null;
            try
            {
                using var ms = new MemoryStream(Source.Attachment.Data);
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.DecodePixelWidth = 720;
                image.StreamSource = ms;
                image.EndInit();
                image.Freeze();
                return image;
            }
            catch { return null; }
        }
    }
    public string ReactionsText => Source.Reactions.Count == 0 ? "" : string.Join(" ", Source.Reactions.Values);
    public Visibility ReactionsVisibility => Source.Reactions.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    public string EditedText => Source.Edited ? "ИЗМ." : "";
    public string StateGlyph => Source.State switch
    {
        "failed" => "\uE783",
        "queued" => "\uE823",
        "scheduled" => "\uE787",
        _ => Source.Mine ? "\uE73E" : ""
    };

    public static MessageVm From(LocalMessage m, string? reply, int textScale) => new()
    {
        Source = m,
        Time = DateTimeOffset.FromUnixTimeSeconds(m.CreatedAt).LocalDateTime.ToString("HH:mm"),
        ReplyPreview = reply ?? "",
        FontSize = 14.5 * Math.Clamp(textScale, 80, 160) / 100d
    };
}

internal sealed class ToolsItemVm
{
    public string Title { get; set; } = "";
    public string Detail { get; set; } = "";
    public string Meta { get; set; } = "";
}