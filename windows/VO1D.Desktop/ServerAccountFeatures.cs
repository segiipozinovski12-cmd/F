using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Input;

namespace VO1D.Desktop;

public partial class MainWindow
{
    private async void ManageUsername_Click(object sender, RoutedEventArgs e)
    {
        if (api == null) { ShowToast("СЕТЬ НЕ ПОДКЛЮЧЕНА"); return; }

        var input = new TextBox
        {
            Text = state.Username ?? "",
            Margin = new Thickness(0, 10, 0, 12),
            Padding = new Thickness(10),
            MinHeight = 40
        };
        var status = new TextBlock { Foreground = Brushes.Gray, Margin = new Thickness(0, 0, 0, 12) };
        var check = ActionButton("ПРОВЕРИТЬ");
        var save = ActionButton("СОХРАНИТЬ");
        var release = ActionButton("ОСВОБОДИТЬ");
        var buttons = new WrapPanel();
        foreach (var b in new[] { check, save, release })
        {
            b.Margin = new Thickness(0, 0, 8, 8);
            buttons.Children.Add(b);
        }

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Username", FontSize = 26, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock { Text = "4–20 символов: a-z, 0-9, _", Foreground = Brushes.Gray, Margin = new Thickness(0, 6, 0, 0) });
        panel.Children.Add(input);
        panel.Children.Add(status);
        panel.Children.Add(buttons);

        var win = PopupWindow("Username", panel, 470, 360);

        check.Click += async (_, _) =>
        {
            try
            {
                var value = input.Text.Trim().TrimStart('@').ToLowerInvariant();
                var result = await api.CheckUsernameAsync(value);
                status.Text = !result.Valid ? "Неверный формат"
                    : result.Available ? "Свободен" : "Уже занят";
            }
            catch (Exception ex) { status.Text = ex.Message; }
        };

        save.Click += async (_, _) =>
        {
            try
            {
                var value = input.Text.Trim().TrimStart('@').ToLowerInvariant();
                var result = await api.SetUsernameAsync(value);
                state.Username = result.Username;
                Save();
                ShowToast("USERNAME СОХРАНЁН");
                win.DialogResult = true;
            }
            catch (Exception ex) { status.Text = ex.Message; }
        };

        release.Click += async (_, _) =>
        {
            try
            {
                await api.ReleaseUsernameAsync();
                state.Username = null;
                Save();
                ShowToast("USERNAME ОСВОБОЖДЁН");
                win.DialogResult = true;
            }
            catch (Exception ex) { status.Text = ex.Message; }
        };

        win.ShowDialog();
    }

    private async void ManageServerPrivacy_Click(object sender, RoutedEventArgs e)
    {
        if (api == null) { ShowToast("СЕТЬ НЕ ПОДКЛЮЧЕНА"); return; }

        try
        {
            var current = await api.GetPrivacyAsync();

            var discoverable = new CheckBox
            {
                Content = "Разрешить поиск по username / короткому ID",
                IsChecked = current.Discoverable,
                Foreground = Brushes.White,
                Margin = new Thickness(0, 12, 0, 10)
            };
            var trustedCalls = new CheckBox
            {
                Content = "Звонки только доверенным контактам",
                IsChecked = current.TrustedCalls,
                Foreground = Brushes.White,
                Margin = new Thickness(0, 0, 0, 12)
            };
            var inactivity = new ComboBox { Margin = new Thickness(0, 4, 0, 16) };
            var values = new[] { 0, 30, 90, 180, 365 };
            inactivity.ItemsSource = new[] { "Не удалять", "30 дней", "90 дней", "180 дней", "365 дней" };
            inactivity.SelectedIndex = Math.Max(0, Array.IndexOf(values, current.InactivityDays));

            var save = ActionButton("СОХРАНИТЬ");
            var panel = new StackPanel { Margin = new Thickness(22) };
            panel.Children.Add(new TextBlock { Text = "Приватность relay", FontSize = 26, FontWeight = FontWeights.Black });
            panel.Children.Add(discoverable);
            panel.Children.Add(trustedCalls);
            panel.Children.Add(new TextBlock { Text = "Удаление аккаунта при неактивности", Foreground = Brushes.Gray });
            panel.Children.Add(inactivity);
            panel.Children.Add(save);

            var win = PopupWindow("Relay privacy", panel, 500, 410);
            save.Click += async (_, _) =>
            {
                try
                {
                    var days = values[Math.Max(0, inactivity.SelectedIndex)];
                    await api.SetPrivacyAsync(discoverable.IsChecked == true, days, trustedCalls.IsChecked == true);
                    ShowToast("ПРИВАТНОСТЬ ОБНОВЛЕНА");
                    win.DialogResult = true;
                }
                catch (Exception ex) { ShowToast(ex.Message); }
            };
            win.ShowDialog();
        }
        catch (Exception ex) { ShowToast(ex.Message); }
    }

    private async void ManageSessions_Click(object sender, RoutedEventArgs e)
    {
        if (api == null) { ShowToast("СЕТЬ НЕ ПОДКЛЮЧЕНА"); return; }

        try
        {
            var sessions = await api.ListSessionsAsync();
            var rows = sessions.Select(s => new SessionChoice(
                s,
                (s.Current ? "ТЕКУЩАЯ · " : "") +
                DateTimeOffset.FromUnixTimeSeconds(s.ExpiresAt).LocalDateTime.ToString("dd.MM.yyyy HH:mm") +
                " · " + s.Id[..Math.Min(12, s.Id.Length)].ToUpperInvariant())).ToList();

            var list = new ListBox
            {
                ItemsSource = rows,
                DisplayMemberPath = nameof(SessionChoice.Title),
                Background = Brushes.Transparent,
                Foreground = Brushes.White,
                BorderThickness = new Thickness(0),
                Margin = new Thickness(0, 12, 0, 14)
            };
            var revoke = ActionButton("ОТОЗВАТЬ ОСТАЛЬНЫЕ");
            var panel = new StackPanel { Margin = new Thickness(22) };
            panel.Children.Add(new TextBlock { Text = "Сессии relay", FontSize = 26, FontWeight = FontWeights.Black });
            panel.Children.Add(new TextBlock { Text = "Отзыв удаляет все серверные bearer-сессии кроме текущей.", Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) });
            panel.Children.Add(list);
            panel.Children.Add(revoke);
            var win = PopupWindow("Сессии", panel, 600, 500);

            revoke.Click += async (_, _) =>
            {
                try
                {
                    await api.RevokeOtherSessionsAsync();
                    ShowToast("ОСТАЛЬНЫЕ СЕССИИ ОТОЗВАНЫ");
                    win.DialogResult = true;
                }
                catch (Exception ex) { ShowToast(ex.Message); }
            };
            win.ShowDialog();
        }
        catch (Exception ex) { ShowToast(ex.Message); }
    }

    private async void ShowRelayStorage_Click(object sender, RoutedEventArgs e)
    {
        if (api == null) { ShowToast("СЕТЬ НЕ ПОДКЛЮЧЕНА"); return; }

        try
        {
            var s = await api.StorageAsync();
            MessageBox.Show(
                this,
                $"Сообщений в relay-очереди: {s.QueuedMessages}\n" +
                $"Mailbox bytes: {FormatBytes(s.MailboxBytes)}\n" +
                $"Файлов: {s.Files}\n" +
                $"File bytes: {FormatBytes(s.FileBytes)}",
                "VO1D · Relay storage",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (Exception ex) { ShowToast(ex.Message); }
    }

    private async void ManageInvites_Click(object sender, RoutedEventArgs e)
    {
        if (api == null) { ShowToast("СЕТЬ НЕ ПОДКЛЮЧЕНА"); return; }

        var list = new ListBox
        {
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12)
        };
        var tokenBox = new TextBox
        {
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 58,
            Margin = new Thickness(0, 0, 0, 12)
        };

        var create1 = ActionButton("1 ЧАС / 1");
        var createDay = ActionButton("24 Ч / 1");
        var createMulti = ActionButton("7 ДНЕЙ / 5");
        var revoke = ActionButton("ОТОЗВАТЬ");
        var buttons = new WrapPanel();
        foreach (var b in new[] { create1, createDay, createMulti, revoke })
        {
            b.Margin = new Thickness(0, 0, 8, 8);
            buttons.Children.Add(b);
        }

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Одноразовые приглашения", FontSize = 25, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock { Text = "Relay хранит хэш секрета, а не сам invite-токен.", Foreground = Brushes.Gray, Margin = new Thickness(0, 6, 0, 0) });
        panel.Children.Add(list);
        panel.Children.Add(new TextBlock { Text = "Последний созданный токен", Foreground = Brushes.Gray });
        panel.Children.Add(tokenBox);
        panel.Children.Add(buttons);
        var win = PopupWindow("Invites", panel, 610, 600);

        async Task Reload()
        {
            try
            {
                var items = await api.ListInvitesAsync();
                list.ItemsSource = items.Select(x => new InviteChoice(
                    x,
                    $"{DateTimeOffset.FromUnixTimeSeconds(x.ExpiresAt).LocalDateTime:dd.MM HH:mm} · осталось {x.Remaining} · {x.Id[..Math.Min(12, x.Id.Length)]}")).ToList();
            }
            catch (Exception ex) { ShowToast(ex.Message); }
        }

        async Task Create(int seconds, int uses)
        {
            try
            {
                var receipt = await api.CreateInviteAsync(seconds, uses);
                tokenBox.Text = receipt.Token ?? "";
                await Reload();
            }
            catch (Exception ex) { ShowToast(ex.Message); }
        }

        create1.Click += async (_, _) => await Create(3600, 1);
        createDay.Click += async (_, _) => await Create(86400, 1);
        createMulti.Click += async (_, _) => await Create(604800, 5);
        revoke.Click += async (_, _) =>
        {
            if (list.SelectedItem is not InviteChoice row) return;
            try
            {
                await api.RevokeInviteAsync(row.Invite.Id);
                await Reload();
            }
            catch (Exception ex) { ShowToast(ex.Message); }
        };

        await Reload();
        win.ShowDialog();
    }

    private static string FormatBytes(long bytes) =>
        bytes < 1024 ? $"{bytes} B" :
        bytes < 1024 * 1024 ? $"{bytes / 1024d:F1} KB" :
        $"{bytes / 1024d / 1024d:F1} MB";

    private sealed record SessionChoice(Vo1dApi.RelaySessionDto Session, string Title);
    private sealed record InviteChoice(Vo1dApi.InviteReceiptDto Invite, string Title);
}
