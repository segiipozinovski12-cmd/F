using Microsoft.Win32;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace VO1D.Desktop;

public partial class MainWindow
{
    private DateTimeOffset lastTypingSent = DateTimeOffset.MinValue;
    private readonly Dictionary<string, DispatcherTimer> typingTimers = new();

    private void AttachMenu_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button button && button.ContextMenu != null)
        {
            button.ContextMenu.PlacementTarget = button;
            button.ContextMenu.IsOpen = true;
        }
    }

    private void AttachFile_Click(object sender, RoutedEventArgs e) =>
        Attach_Click(AttachButton, new RoutedEventArgs());

    private async Task SendTypingPulseAsync()
    {
        if (selectedRoom == null || IsSavedRoom(selectedRoom) || signal == null || api == null) return;
        if (DateTimeOffset.UtcNow - lastTypingSent < TimeSpan.FromSeconds(5)) return;
        lastTypingSent = DateTimeOffset.UtcNow;
        try { await SendControlEventAsync("typing", "", null); } catch { }
    }

    private async Task MarkSelectedRoomReadAsync()
    {
        if (selectedRoom == null) return;
        selectedRoom.Unread = 0;
        if (IsSavedRoom(selectedRoom) || !state.Preferences.ReadReceipts)
        {
            Save();
            return;
        }

        var unread = state.Messages
            .Where(m => m.RoomId == selectedRoom.Id && !m.Mine && !m.ReadBy.Contains(crypto.Card.Id))
            .ToList();

        foreach (var message in unread)
            message.ReadBy.Add(crypto.Card.Id);

        Save();

        // The iOS implementation sends receipts to the original sender. The current
        // desktop helper broadcasts within a room, so keep network receipts to DMs
        // until per-recipient group receipts are introduced.
        if (!selectedRoom.IsGroup)
        {
            foreach (var message in unread)
            {
                try { await SendControlEventAsync("read", message.Id, null); } catch { }
            }
        }
    }

    private bool HandleParityIncoming(
        string kind,
        RoomState? room,
        string? target,
        string? value,
        ContactCard sender)
    {
        if (kind == "typing" && room != null)
        {
            if (selectedRoom?.Id == room.Id)
            {
                TypingText.Text = state.Contacts.FirstOrDefault(c => c.Card.Id == sender.Id)?.Name is { Length: > 0 } name
                    ? $"{name} печатает…"
                    : "Собеседник печатает…";
                TypingText.Visibility = Visibility.Visible;

                if (!typingTimers.TryGetValue(room.Id, out var timer))
                {
                    timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
                    timer.Tick += (_, _) =>
                    {
                        timer.Stop();
                        if (selectedRoom?.Id == room.Id) TypingText.Visibility = Visibility.Collapsed;
                    };
                    typingTimers[room.Id] = timer;
                }
                timer.Stop();
                timer.Start();
            }
            return true;
        }

        if (target == null) return false;
        var message = state.Messages.FirstOrDefault(m => m.Id == target);
        if (message == null) return false;

        if (kind == "read")
        {
            if (!message.ReadBy.Contains(sender.Id)) message.ReadBy.Add(sender.Id);
            if (message.Mine) message.State = "read";
            return true;
        }
        if (kind == "delivered")
        {
            if (!message.DeliveredTo.Contains(sender.Id)) message.DeliveredTo.Add(sender.Id);
            if (message.Mine && message.State != "read") message.State = "delivered";
            return true;
        }
        if (kind == "pollVote" && value != null && message.Poll != null && !message.Poll.Closed)
        {
            foreach (var option in message.Poll.Options) option.VoterIDs.Remove(sender.Id);
            var selected = message.Poll.Options.FirstOrDefault(o => o.Id == value);
            if (selected != null && !selected.VoterIDs.Contains(sender.Id)) selected.VoterIDs.Add(sender.Id);
            return true;
        }
        if (kind == "pollClose" && message.Poll != null)
        {
            message.Poll.Closed = true;
            return true;
        }

        return false;
    }

    private void ExpireMessages()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var before = state.Messages.Count;
        state.Messages.RemoveAll(m => m.ExpiresAt.HasValue && m.ExpiresAt.Value <= now);
        if (state.Messages.Count != before)
        {
            Save();
            RefreshAll();
        }
    }

    private async void MessageForward_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as MenuItem)?.CommandParameter is not MessageVm vm) return;
        var targetRoom = PickRoom("Переслать сообщение");
        if (targetRoom == null) return;

        var source = vm.Source;
        var oldRoom = selectedRoom;
        var oldPeer = selected;
        try
        {
            selectedRoom = targetRoom;
            selected = PeerFor(targetRoom);
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var forwarded = new LocalMessage
            {
                Id = Guid.NewGuid().ToString(),
                RoomId = targetRoom.Id,
                PeerId = selected?.Card.Id ?? "",
                SenderId = crypto.Card.Id,
                Mine = true,
                Text = source.Text,
                CreatedAt = now,
                Attachment = source.Attachment == null ? null : new AttachmentState
                {
                    Name = source.Attachment.Name,
                    Mime = source.Attachment.Mime,
                    Data = source.Attachment.Data.ToArray(),
                    ViewSeconds = source.Attachment.ViewSeconds
                },
                ForwardedFrom = source.ForwardedFrom ?? source.SenderId,
                Poll = source.Poll == null ? null : ClonePoll(source.Poll),
                Topic = source.Topic,
                State = IsSavedRoom(targetRoom) ? "sent" : "queued"
            };

            state.Messages.Add(forwarded);
            Save();
            if (!IsSavedRoom(targetRoom))
            {
                await SendWireMessageAsync(forwarded);
                forwarded.State = "sent";
                Save();
            }
            ShowToast("СООБЩЕНИЕ ПЕРЕСЛАНО");
        }
        catch (Exception ex)
        {
            ShowToast(ex.Message);
        }
        finally
        {
            selectedRoom = oldRoom;
            selected = oldPeer;
            RefreshAll();
        }
    }

    private async void CreatePoll_Click(object sender, RoutedEventArgs e)
    {
        if (selectedRoom == null) return;
        var poll = PollEditor();
        if (poll == null) return;

        var message = new LocalMessage
        {
            Id = Guid.NewGuid().ToString(),
            RoomId = selectedRoom.Id,
            PeerId = selected?.Card.Id ?? "",
            SenderId = crypto.Card.Id,
            Mine = true,
            Text = "",
            CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            Poll = poll,
            State = IsSavedRoom(selectedRoom) ? "sent" : "queued"
        };

        state.Messages.Add(message);
        Save();
        RefreshAll();

        if (!IsSavedRoom(selectedRoom))
        {
            try
            {
                await SendWireMessageAsync(message);
                message.State = "sent";
                Save();
                RefreshAll();
            }
            catch (Exception ex)
            {
                message.State = "failed";
                Save();
                RefreshAll();
                ShowToast(ex.Message);
            }
        }
    }

    private async void MessageVotePoll_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as MenuItem)?.CommandParameter is not MessageVm vm ||
            vm.Source.Poll is not { } poll ||
            poll.Closed) return;

        var option = PickPollOption(poll);
        if (option == null) return;

        foreach (var item in poll.Options) item.VoterIDs.Remove(crypto.Card.Id);
        if (!option.VoterIDs.Contains(crypto.Card.Id)) option.VoterIDs.Add(crypto.Card.Id);
        Save();
        RefreshAll();

        try { await SendControlEventAsync("pollVote", vm.Source.Id, option.Id); }
        catch (Exception ex) { ShowToast(ex.Message); }
    }

    private async void MessageClosePoll_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as MenuItem)?.CommandParameter is not MessageVm vm ||
            !vm.Source.Mine ||
            vm.Source.Poll is not { } poll ||
            poll.Closed) return;
        poll.Closed = true;
        Save();
        RefreshAll();
        try { await SendControlEventAsync("pollClose", vm.Source.Id, "1"); }
        catch (Exception ex) { ShowToast(ex.Message); }
    }

    private void AttachEphemeral_Click(object sender, RoutedEventArgs e)
    {
        if (selectedRoom == null) return;
        var dialog = new OpenFileDialog
        {
            Title = "Фото с таймером",
            Filter = "Изображения|*.png;*.jpg;*.jpeg;*.webp;*.gif",
            Multiselect = false
        };
        if (dialog.ShowDialog(this) != true) return;

        var info = new FileInfo(dialog.FileName);
        var max = Math.Clamp(state.Preferences.FileLimitMb, 1, 50) * 1024L * 1024L;
        if (info.Length > max) { ShowToast($"Файл больше лимита {state.Preferences.FileLimitMb} МБ"); return; }

        var seconds = PickEphemeralSeconds();
        if (seconds == null) return;

        pendingAttachment = new AttachmentState
        {
            Name = info.Name,
            Mime = GuessMime(info.Extension),
            Data = File.ReadAllBytes(info.FullName),
            ViewSeconds = seconds.Value
        };
        PendingAttachmentText.Text = $"Фото с таймером · {seconds} сек · {info.Name}";
        PendingAttachmentText.Visibility = Visibility.Visible;
    }

    private void MessageMedia_Click(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not MessageVm vm) return;
        var message = vm.Source;
        if (message.Attachment?.ViewSeconds is not > 0 || message.OpenedAt.HasValue) return;

        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        message.OpenedAt = now;
        message.ExpiresAt = now + Math.Clamp(message.Attachment.ViewSeconds.Value, 1, 120);
        Save();
        RefreshAll();
    }

    private RoomState? PickRoom(string title)
    {
        var candidates = state.Rooms.Where(r => !state.HiddenRooms.Contains(r.Id)).ToList();
        if (candidates.Count == 0) return null;

        RoomState? result = null;
        var list = new ListBox
        {
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12),
            DisplayMemberPath = nameof(RoomChoice.Title)
        };
        var choices = candidates.Select(r => new RoomChoice(r, ResolveRoomTitle(r))).ToList();
        list.ItemsSource = choices;
        list.SelectedIndex = 0;

        var ok = new Button
        {
            Content = "ПЕРЕСЛАТЬ",
            Height = 44,
            Background = Brushes.White,
            Foreground = Brushes.Black,
            BorderThickness = new Thickness(0),
            FontWeight = FontWeights.Bold
        };

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 24, FontWeight = FontWeights.Black });
        panel.Children.Add(list);
        panel.Children.Add(ok);

        var win = PopupWindow(title, panel, 430, 520);
        ok.Click += (_, _) =>
        {
            if (list.SelectedItem is RoomChoice choice) result = choice.Room;
            win.DialogResult = result != null;
        };
        list.MouseDoubleClick += (_, _) => ok.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        win.ShowDialog();
        return result;
    }

    private PollState? PollEditor()
    {
        var question = new TextBox { Margin = new Thickness(0, 12, 0, 8), MinHeight = 38 };
        var options = Enumerable.Range(0, 4).Select(i => new TextBox
        {
            Margin = new Thickness(0, 0, 0, 7),
            MinHeight = 34
        }).ToArray();
        var privateVotes = new CheckBox { Content = "Приватные голоса", Foreground = Brushes.White, Margin = new Thickness(0, 4, 0, 12) };
        var create = new Button { Content = "СОЗДАТЬ ОПРОС", Height = 44, Background = Brushes.White, Foreground = Brushes.Black, FontWeight = FontWeights.Bold };

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Новый опрос", FontSize = 24, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock { Text = "Вопрос", Foreground = Brushes.Gray, Margin = new Thickness(0, 10, 0, 0) });
        panel.Children.Add(question);
        for (var i = 0; i < options.Length; i++)
        {
            options[i].ToolTip = $"Вариант {i + 1}";
            panel.Children.Add(options[i]);
        }
        panel.Children.Add(privateVotes);
        panel.Children.Add(create);

        PollState? result = null;
        var win = PopupWindow("Опрос", panel, 460, 520);
        create.Click += (_, _) =>
        {
            var q = question.Text.Trim();
            var clean = options.Select(x => x.Text.Trim()).Where(x => x.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).Take(10).ToList();
            if (q.Length == 0 || clean.Count < 2)
            {
                MessageBox.Show(win, "Нужен вопрос и минимум два варианта.", "VO1D");
                return;
            }
            result = new PollState
            {
                Question = q.Length > 240 ? q[..240] : q,
                PrivateVotes = privateVotes.IsChecked == true,
                Options = clean.Select(x => new PollOptionState { Text = x }).ToList()
            };
            win.DialogResult = true;
        };
        win.ShowDialog();
        return result;
    }

    private PollOptionState? PickPollOption(PollState poll)
    {
        PollOptionState? result = null;
        var list = new ListBox
        {
            ItemsSource = poll.Options,
            DisplayMemberPath = nameof(PollOptionState.Text),
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12)
        };
        var vote = new Button { Content = "ГОЛОСОВАТЬ", Height = 44, Background = Brushes.White, Foreground = Brushes.Black, FontWeight = FontWeights.Bold };
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = poll.Question, TextWrapping = TextWrapping.Wrap, FontSize = 21, FontWeight = FontWeights.Black });
        panel.Children.Add(list);
        panel.Children.Add(vote);
        var win = PopupWindow("Опрос", panel, 440, 460);
        vote.Click += (_, _) =>
        {
            result = list.SelectedItem as PollOptionState;
            if (result != null) win.DialogResult = true;
        };
        win.ShowDialog();
        return result;
    }

    private int? PickEphemeralSeconds()
    {
        var choices = new[] { 5, 10, 30, 60 };
        var list = new ListBox
        {
            ItemsSource = choices.Select(x => $"{x} секунд").ToArray(),
            SelectedIndex = 1,
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12)
        };
        var ok = new Button { Content = "ГОТОВО", Height = 44, Background = Brushes.White, Foreground = Brushes.Black, FontWeight = FontWeights.Bold };
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Таймер просмотра", FontSize = 22, FontWeight = FontWeights.Black });
        panel.Children.Add(list);
        panel.Children.Add(ok);
        var win = PopupWindow("Таймер", panel, 360, 370);
        int? result = null;
        ok.Click += (_, _) => { if (list.SelectedIndex >= 0) { result = choices[list.SelectedIndex]; win.DialogResult = true; } };
        win.ShowDialog();
        return result;
    }

    private Window PopupWindow(string title, UIElement content, double width, double height) =>
        new()
        {
            Owner = this,
            Title = title,
            Width = width,
            Height = height,
            MinWidth = Math.Min(width, 340),
            MinHeight = Math.Min(height, 300),
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = new SolidColorBrush(Color.FromRgb(10, 10, 10)),
            Foreground = Brushes.White,
            Content = content,
            ResizeMode = ResizeMode.CanResizeWithGrip
        };

    private static PollState ClonePoll(PollState poll) => new()
    {
        Question = poll.Question,
        PrivateVotes = poll.PrivateVotes,
        PrivateCounts = poll.PrivateCounts == null ? null : new Dictionary<string, int>(poll.PrivateCounts),
        Closed = poll.Closed,
        Options = poll.Options.Select(o => new PollOptionState
        {
            Id = o.Id,
            Text = o.Text,
            VoterIDs = new List<string>(o.VoterIDs)
        }).ToList()
    };

    private sealed record RoomChoice(RoomState Room, string Title);
}

internal sealed partial class MessageVm
{
    public Visibility ForwardedVisibility => string.IsNullOrWhiteSpace(Source.ForwardedFrom) ? Visibility.Collapsed : Visibility.Visible;
    public string ForwardedText => string.IsNullOrWhiteSpace(Source.ForwardedFrom) ? "" : "ПЕРЕСЛАНО";
    public Visibility PollVisibility => Source.Poll == null ? Visibility.Collapsed : Visibility.Visible;
    public string PollText
    {
        get
        {
            if (Source.Poll == null) return "";
            var lines = Source.Poll.Options.Select(o => $"• {o.Text}  ·  {o.VoterIDs.Count}");
            var closed = Source.Poll.Closed ? "\nОПРОС ЗАКРЫТ" : "";
            return Source.Poll.Question + "\n" + string.Join("\n", lines) + closed;
        }
    }
    public Visibility EphemeralVisibility => Source.Attachment?.ViewSeconds is > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string EphemeralText => Source.Attachment?.ViewSeconds is > 0 ? $"ТАЙМЕР · {Source.Attachment.ViewSeconds} СЕК" : "";
}
