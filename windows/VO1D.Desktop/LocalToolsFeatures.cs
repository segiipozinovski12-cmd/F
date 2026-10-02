using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace VO1D.Desktop;

public partial class MainWindow
{
    private void CheckLocalReminders()
    {
        if (state.Reminders == null || state.Reminders.Count == 0) return;
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var due = state.Reminders.Where(r => !r.Fired && r.At <= now).OrderBy(r => r.At).ToList();
        if (due.Count == 0) return;

        foreach (var reminder in due)
        {
            reminder.Fired = true;
            var message = state.Messages.FirstOrDefault(m => m.Id == reminder.MessageId);
            var room = state.Rooms.FirstOrDefault(r => r.Id == reminder.RoomId);
            var preview = message?.Text;
            if (string.IsNullOrWhiteSpace(preview)) preview = message?.Attachment?.Name ?? "Сообщение";
            if (preview.Length > 120) preview = preview[..120] + "…";

            MessageBox.Show(
                this,
                preview,
                "VO1D · Напоминание · " + ResolveRoomTitle(room),
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }

        Save();
        RefreshTools();
    }

    private void ApplyLocalRetention()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var before = state.Messages.Count;

        state.Messages.RemoveAll(message =>
        {
            var days = state.RoomRetentionDays.TryGetValue(message.RoomId, out var roomDays)
                ? roomDays : state.Preferences.DefaultRetentionDays;
            if (days <= 0) return false;
            return message.CreatedAt < now - days * 86400L;
        });

        if (state.Messages.Count != before)
        {
            Save();
            RefreshAll();
        }
    }

    private void AppendLocalTools()
    {
        foreach (var reminder in state.Reminders.Where(r => !r.Fired).OrderBy(r => r.At))
        {
            var message = state.Messages.FirstOrDefault(m => m.Id == reminder.MessageId);
            toolsItems.Add(new ToolsItemVm
            {
                Title = "Напоминание · " + ResolveRoomTitle(state.Rooms.FirstOrDefault(r => r.Id == reminder.RoomId)),
                Detail = message?.Text ?? message?.Attachment?.Name ?? "Сообщение",
                Meta = DateTimeOffset.FromUnixTimeSeconds(reminder.At).LocalDateTime.ToString("dd.MM HH:mm")
            });
        }

        foreach (var snippet in state.Snippets.Take(12))
        {
            toolsItems.Add(new ToolsItemVm
            {
                Title = "Шаблон · " + snippet.Title,
                Detail = snippet.Text,
                Meta = "SNIPPET"
            });
        }

        foreach (var failed in state.Messages.Where(m => m.State is "failed" or "queued").Take(20))
        {
            toolsItems.Add(new ToolsItemVm
            {
                Title = "Очередь · " + ResolveRoomTitle(state.Rooms.FirstOrDefault(r => r.Id == failed.RoomId)),
                Detail = string.IsNullOrWhiteSpace(failed.Text) ? failed.Attachment?.Name ?? "Сообщение" : failed.Text,
                Meta = failed.State.ToUpperInvariant()
            });
        }

        foreach (var folder in state.Folders)
        {
            toolsItems.Add(new ToolsItemVm
            {
                Title = "Папка · " + folder.Name,
                Detail = $"{folder.RoomIds.Count} чатов",
                Meta = "FOLDER"
            });
        }
    }

    private void ManageFolders_Click(object sender, RoutedEventArgs e)
    {
        var list = new ListBox
        {
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12),
            DisplayMemberPath = nameof(ChatFolderState.Name),
            ItemsSource = state.Folders
        };

        var create = ActionButton("НОВАЯ");
        var assign = ActionButton("ДОБАВИТЬ ЧАТ");
        var remove = ActionButton("УБРАТЬ ЧАТ");
        var rename = ActionButton("ПЕРЕИМЕНОВАТЬ");
        var delete = ActionButton("УДАЛИТЬ");

        var buttons = new WrapPanel();
        foreach (var b in new[] { create, assign, remove, rename, delete })
        {
            b.Margin = new Thickness(0, 0, 8, 8);
            buttons.Children.Add(b);
        }

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Папки чатов", FontSize = 26, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock { Text = "Локальная организация. Названия папок не отправляются на relay.", Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) });
        panel.Children.Add(list);
        panel.Children.Add(buttons);
        var win = PopupWindow("Папки", panel, 540, 550);

        void Reload()
        {
            list.ItemsSource = null;
            list.ItemsSource = state.Folders;
            RefreshTools();
        }

        create.Click += (_, _) =>
        {
            var name = PromptTextValue("Новая папка", "Название папки", "");
            if (string.IsNullOrWhiteSpace(name)) return;
            state.Folders.Add(new ChatFolderState { Name = name.Trim()[..Math.Min(name.Trim().Length, 40)] });
            Save(); Reload();
        };

        assign.Click += (_, _) =>
        {
            if (list.SelectedItem is not ChatFolderState folder || selectedRoom == null)
            {
                ShowToast("ВЫБЕРИ ПАПКУ И ЧАТ");
                return;
            }
            if (!folder.RoomIds.Contains(selectedRoom.Id)) folder.RoomIds.Add(selectedRoom.Id);
            Save(); Reload();
        };

        remove.Click += (_, _) =>
        {
            if (list.SelectedItem is not ChatFolderState folder || selectedRoom == null) return;
            folder.RoomIds.Remove(selectedRoom.Id);
            Save(); Reload();
        };

        rename.Click += (_, _) =>
        {
            if (list.SelectedItem is not ChatFolderState folder) return;
            var name = PromptTextValue("Переименовать папку", "Новое название", folder.Name);
            if (string.IsNullOrWhiteSpace(name)) return;
            folder.Name = name.Trim()[..Math.Min(name.Trim().Length, 40)];
            Save(); Reload();
        };

        delete.Click += (_, _) =>
        {
            if (list.SelectedItem is not ChatFolderState folder) return;
            state.Folders.Remove(folder);
            Save(); Reload();
        };

        win.ShowDialog();
    }

    private void ManageSnippets_Click(object sender, RoutedEventArgs e)
    {
        var list = new ListBox
        {
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12),
            DisplayMemberPath = nameof(TextSnippetState.Title),
            ItemsSource = state.Snippets
        };

        var insert = ActionButton("ВСТАВИТЬ");
        var create = ActionButton("НОВЫЙ");
        var delete = ActionButton("УДАЛИТЬ");
        var buttons = new WrapPanel();
        foreach (var b in new[] { insert, create, delete })
        {
            b.Margin = new Thickness(0, 0, 8, 8);
            buttons.Children.Add(b);
        }

        var preview = new TextBlock { Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap, MaxHeight = 80 };
        list.SelectionChanged += (_, _) => preview.Text = (list.SelectedItem as TextSnippetState)?.Text ?? "";

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Шаблоны", FontSize = 26, FontWeight = FontWeights.Black });
        panel.Children.Add(list);
        panel.Children.Add(preview);
        panel.Children.Add(buttons);
        var win = PopupWindow("Шаблоны", panel, 520, 530);

        void Reload()
        {
            list.ItemsSource = null;
            list.ItemsSource = state.Snippets;
            RefreshTools();
        }

        insert.Click += (_, _) =>
        {
            if (list.SelectedItem is not TextSnippetState snippet || selectedRoom == null) return;
            ComposerBox.Text = string.IsNullOrWhiteSpace(ComposerBox.Text)
                ? snippet.Text : ComposerBox.Text + Environment.NewLine + snippet.Text;
            ComposerBox.CaretIndex = ComposerBox.Text.Length;
            ComposerBox.Focus();
            win.Close();
        };

        create.Click += (_, _) =>
        {
            var title = PromptTextValue("Новый шаблон", "Название", "");
            if (string.IsNullOrWhiteSpace(title)) return;
            var text = PromptTextValue("Текст шаблона", "Текст", "");
            if (string.IsNullOrWhiteSpace(text)) return;
            state.Snippets.Add(new TextSnippetState
            {
                Title = title.Trim()[..Math.Min(title.Trim().Length, 40)],
                Text = text.Trim()[..Math.Min(text.Trim().Length, 4000)]
            });
            Save(); Reload();
        };

        delete.Click += (_, _) =>
        {
            if (list.SelectedItem is not TextSnippetState snippet) return;
            state.Snippets.Remove(snippet);
            Save(); Reload();
        };

        win.ShowDialog();
    }

    private void ManageReminders_Click(object sender, RoutedEventArgs e)
    {
        var rows = state.Reminders
            .Where(r => !r.Fired)
            .OrderBy(r => r.At)
            .Select(r => new ReminderChoice(
                r,
                DateTimeOffset.FromUnixTimeSeconds(r.At).LocalDateTime.ToString("dd.MM HH:mm") + " · " +
                ResolveRoomTitle(state.Rooms.FirstOrDefault(room => room.Id == r.RoomId))))
            .ToList();

        var list = new ListBox
        {
            ItemsSource = rows,
            DisplayMemberPath = nameof(ReminderChoice.Title),
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12)
        };

        var delete = ActionButton("УДАЛИТЬ");
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Напоминания", FontSize = 26, FontWeight = FontWeights.Black });
        panel.Children.Add(list);
        panel.Children.Add(delete);
        var win = PopupWindow("Напоминания", panel, 540, 500);

        delete.Click += (_, _) =>
        {
            if (list.SelectedItem is not ReminderChoice row) return;
            state.Reminders.Remove(row.Reminder);
            Save();
            win.Close();
            RefreshTools();
        };

        win.ShowDialog();
    }

    private void MessageReminder_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as MenuItem)?.CommandParameter is not MessageVm vm) return;
        var choices = new[]
        {
            new ReminderDelay("Через 10 минут", TimeSpan.FromMinutes(10)),
            new ReminderDelay("Через 1 час", TimeSpan.FromHours(1)),
            new ReminderDelay("Через 3 часа", TimeSpan.FromHours(3)),
            new ReminderDelay("Завтра", TimeSpan.FromDays(1))
        };
        var list = new ListBox
        {
            ItemsSource = choices,
            DisplayMemberPath = nameof(ReminderDelay.Title),
            SelectedIndex = 0,
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12)
        };
        var ok = ActionButton("НАПОМНИТЬ");
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Напомнить о сообщении", FontSize = 23, FontWeight = FontWeights.Black });
        panel.Children.Add(list);
        panel.Children.Add(ok);
        var win = PopupWindow("Напоминание", panel, 420, 390);
        ok.Click += (_, _) =>
        {
            if (list.SelectedItem is not ReminderDelay delay) return;
            state.Reminders.Add(new LocalReminderState
            {
                MessageId = vm.Source.Id,
                RoomId = vm.Source.RoomId,
                At = DateTimeOffset.UtcNow.Add(delay.Delay).ToUnixTimeSeconds()
            });
            Save(); RefreshTools();
            win.DialogResult = true;
            ShowToast("НАПОМИНАНИЕ ДОБАВЛЕНО");
        };
        win.ShowDialog();
    }

    private async void RetryQueue_Click(object sender, RoutedEventArgs e)
    {
        if (api == null || signal == null)
        {
            ShowToast("СЕТЬ НЕ ПОДКЛЮЧЕНА");
            return;
        }

        var pending = state.Messages
            .Where(m => m.State is "failed" or "queued")
            .OrderBy(m => m.CreatedAt)
            .ToList();
        if (pending.Count == 0)
        {
            ShowToast("ОЧЕРЕДЬ ПУСТА");
            return;
        }

        var oldRoom = selectedRoom;
        var oldPeer = selected;
        var sent = 0;

        foreach (var message in pending)
        {
            var room = state.Rooms.FirstOrDefault(r => r.Id == message.RoomId);
            if (room == null || IsSavedRoom(room)) continue;
            selectedRoom = room;
            selected = PeerFor(room);
            try
            {
                await SendWireMessageAsync(message);
                message.State = "sent";
                sent++;
            }
            catch
            {
                message.State = "failed";
            }
        }

        selectedRoom = oldRoom;
        selected = oldPeer;
        Save();
        RefreshAll();
        ShowToast($"ПОВТОР ОЧЕРЕДИ · ОТПРАВЛЕНО {sent}");
    }

    private void RoomLocalSettings_Click(object sender, RoutedEventArgs e)
    {
        if (selectedRoom == null) return;

        var note = new TextBox
        {
            Text = state.RoomNotes.TryGetValue(selectedRoom.Id, out var savedNote) ? savedNote : selectedRoom.Note,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 80,
            Margin = new Thickness(0, 8, 0, 12)
        };
        var retention = new ComboBox { Margin = new Thickness(0, 5, 0, 12) };
        var retentionValues = new[] { 0, 1, 7, 30, 90 };
        retention.ItemsSource = new[] { "Всегда", "1 день", "7 дней", "30 дней", "90 дней" };
        var currentRetention = state.RoomRetentionDays.TryGetValue(selectedRoom.Id, out var d) ? d : 0;
        retention.SelectedIndex = Math.Max(0, Array.IndexOf(retentionValues, currentRetention));

        var scale = new Slider
        {
            Minimum = 80,
            Maximum = 160,
            TickFrequency = 10,
            IsSnapToTickEnabled = true,
            Value = state.RoomTextScale.TryGetValue(selectedRoom.Id, out var s) ? s : state.Preferences.TextScale,
            Margin = new Thickness(0, 5, 0, 14)
        };

        var save = ActionButton("СОХРАНИТЬ");
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Локальные настройки чата", FontSize = 24, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock { Text = "Заметка", Foreground = Brushes.Gray, Margin = new Thickness(0, 12, 0, 0) });
        panel.Children.Add(note);
        panel.Children.Add(new TextBlock { Text = "Хранение сообщений", Foreground = Brushes.Gray });
        panel.Children.Add(retention);
        panel.Children.Add(new TextBlock { Text = "Размер текста", Foreground = Brushes.Gray });
        panel.Children.Add(scale);
        panel.Children.Add(save);
        var win = PopupWindow("Чат", panel, 470, 540);

        save.Click += (_, _) =>
        {
            state.RoomNotes[selectedRoom.Id] = note.Text.Trim();
            var days = retentionValues[Math.Max(0, retention.SelectedIndex)];
            if (days == 0) state.RoomRetentionDays.Remove(selectedRoom.Id);
            else state.RoomRetentionDays[selectedRoom.Id] = days;
            state.RoomTextScale[selectedRoom.Id] = (int)Math.Round(scale.Value);
            Save();
            RefreshAll();
            win.DialogResult = true;
        };

        win.ShowDialog();
    }

    private void ContactAliasNote_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as MenuItem)?.CommandParameter is not PersonVm vm) return;
        var alias = new TextBox { Text = vm.Contact.Alias, Margin = new Thickness(0, 7, 0, 12) };
        var note = new TextBox
        {
            Text = vm.Contact.Note,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 90,
            Margin = new Thickness(0, 7, 0, 14)
        };
        var save = ActionButton("СОХРАНИТЬ");
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Контакт", FontSize = 24, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock { Text = "Локальный псевдоним", Foreground = Brushes.Gray, Margin = new Thickness(0, 12, 0, 0) });
        panel.Children.Add(alias);
        panel.Children.Add(new TextBlock { Text = "Локальная заметка", Foreground = Brushes.Gray });
        panel.Children.Add(note);
        panel.Children.Add(save);
        var win = PopupWindow("Контакт", panel, 470, 500);

        save.Click += (_, _) =>
        {
            vm.Contact.Alias = alias.Text.Trim()[..Math.Min(alias.Text.Trim().Length, 60)];
            vm.Contact.Note = note.Text.Trim()[..Math.Min(note.Text.Trim().Length, 4000)];
            Save();
            RefreshAll();
            win.DialogResult = true;
        };
        win.ShowDialog();
    }

    private Button ActionButton(string text) => new()
    {
        Content = text,
        MinWidth = 110,
        Height = 40,
        Padding = new Thickness(12, 0, 12, 0),
        Background = Brushes.White,
        Foreground = Brushes.Black,
        BorderThickness = new Thickness(0),
        FontWeight = FontWeights.Bold
    };

    private string? PromptTextValue(string title, string prompt, string initial)
    {
        string? result = null;
        var input = new TextBox
        {
            Text = initial,
            Margin = new Thickness(0, 10, 0, 14),
            Padding = new Thickness(10),
            MinHeight = 38
        };
        var ok = ActionButton("ГОТОВО");
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 24, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock { Text = prompt, Foreground = Brushes.Gray, Margin = new Thickness(0, 7, 0, 0) });
        panel.Children.Add(input);
        panel.Children.Add(ok);
        var win = PopupWindow(title, panel, 430, 310);
        ok.Click += (_, _) =>
        {
            result = input.Text;
            win.DialogResult = true;
        };
        input.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter)
                ok.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        };
        input.Focus();
        win.ShowDialog();
        return result;
    }

    private sealed record ReminderDelay(string Title, TimeSpan Delay);
    private sealed record ReminderChoice(LocalReminderState Reminder, string Title);
}
