using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace VO1D.Desktop;

public partial class MainWindow
{
    private async void RefreshRelayPrivacy_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var privacy = await api.GetPrivacyAsync();
            RelayDiscoverableToggle.IsChecked = privacy.Discoverable;
            RelayTrustedCallsToggle.IsChecked = privacy.TrustedCalls;
            RelayInactivityDaysBox.Text = privacy.InactivityDays.ToString();
            RelayPrivacyStatus.Text =
                $"DISCOVERABLE {(privacy.Discoverable ? "ON" : "OFF")} · INACTIVITY {privacy.InactivityDays}D · TRUSTED CALLS {(privacy.TrustedCalls ? "ON" : "OFF")}";
        }
        catch (Exception ex)
        {
            RelayPrivacyStatus.Text = "Ошибка relay privacy";
            ShowToast("PRIVACY: " + ex.Message);
        }
    }

    private async void SaveRelayPrivacy_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(RelayInactivityDaysBox.Text.Trim(), out var days) || days < 0 || days > 3650)
        {
            ShowToast("НЕВЕРНЫЙ СРОК НЕАКТИВНОСТИ");
            return;
        }

        try
        {
            var discoverable = RelayDiscoverableToggle.IsChecked == true;
            var trustedCalls = RelayTrustedCallsToggle.IsChecked == true;
            await api.SetPrivacyAsync(discoverable, days, trustedCalls);
            RelayPrivacyStatus.Text =
                $"DISCOVERABLE {(discoverable ? "ON" : "OFF")} · INACTIVITY {days}D · TRUSTED CALLS {(trustedCalls ? "ON" : "OFF")}";
            ShowToast("RELAY PRIVACY СОХРАНЕНА");
        }
        catch (Exception ex)
        {
            ShowToast("PRIVACY: " + ex.Message);
        }
    }

    private async void CheckUsername_Click(object sender, RoutedEventArgs e)
    {
        var username = CleanUsername(RelayUsernameBox.Text);
        if (username.Length == 0)
        {
            RelayUsernameStatus.Text = "Введи username";
            return;
        }

        try
        {
            var result = await api.CheckUsernameAsync(username);
            RelayUsernameStatus.Text = !result.Valid
                ? "Недопустимый username"
                : result.Available
                    ? "@" + result.Username + " · свободен"
                    : "@" + result.Username + " · занят";
        }
        catch (Exception ex)
        {
            RelayUsernameStatus.Text = ex.Message;
        }
    }

    private async void SetUsername_Click(object sender, RoutedEventArgs e)
    {
        var username = CleanUsername(RelayUsernameBox.Text);
        if (username.Length == 0)
        {
            ShowToast("ВВЕДИ USERNAME");
            return;
        }

        try
        {
            var result = await api.SetUsernameAsync(username);
            state.Username = result.Username;
            RelayUsernameBox.Text = result.Username;
            RelayUsernameStatus.Text = "@" + result.Username + " · установлен";
            Save();
            ShowToast("USERNAME ОБНОВЛЁН");
        }
        catch (Exception ex)
        {
            ShowToast("USERNAME: " + ex.Message);
        }
    }

    private async void ReleaseUsername_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await api.ReleaseUsernameAsync();
            state.Username = null;
            RelayUsernameBox.Clear();
            RelayUsernameStatus.Text = "Не установлен";
            Save();
            ShowToast("USERNAME ОСВОБОЖДЁН");
        }
        catch (Exception ex)
        {
            ShowToast("USERNAME: " + ex.Message);
        }
    }

    private static string CleanUsername(string? value) =>
        (value ?? "").Trim().TrimStart('@').ToLowerInvariant();

    private async void ManageInvites_Click(object sender, RoutedEventArgs e)
    {
        var list = new ListBox
        {
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12),
            MinHeight = 180
        };

        var tokenBox = new TextBox
        {
            Margin = new Thickness(0, 8, 0, 10),
            Padding = new Thickness(10),
            FontFamily = new FontFamily("Consolas"),
            Background = new SolidColorBrush(Color.FromArgb(30, 255, 255, 255)),
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            TextWrapping = TextWrapping.Wrap
        };

        var refresh = ActionButton("ОБНОВИТЬ");
        var create = ActionButton("СОЗДАТЬ 1× / 1 ЧАС");
        var redeem = ActionButton("ПОГАСИТЬ TOKEN");
        var revoke = ActionButton("ОТОЗВАТЬ");

        var buttons = new WrapPanel();
        foreach (var b in new[] { refresh, create, redeem, revoke })
        {
            b.Margin = new Thickness(0, 0, 8, 8);
            buttons.Children.Add(b);
        }

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Одноразовые приглашения", FontSize = 26, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock
        {
            Text = "Создавай ограниченные invite-токены, отзывай их или добавляй контакт по полученному токену.",
            Foreground = Brushes.Gray,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0)
        });
        panel.Children.Add(tokenBox);
        panel.Children.Add(buttons);
        panel.Children.Add(list);

        var win = PopupWindow("Invites", panel, 650, 600);

        async Task Reload()
        {
            list.Items.Clear();
            var invites = await api.ListInvitesAsync();
            foreach (var invite in invites.OrderByDescending(x => x.ExpiresAt))
            {
                var expires = DateTimeOffset.FromUnixTimeSeconds(invite.ExpiresAt).LocalDateTime.ToString("dd.MM HH:mm");
                list.Items.Add(new ListBoxItem
                {
                    Content = $"{invite.Id} · осталось {invite.Remaining} · до {expires}",
                    Tag = invite,
                    Foreground = Brushes.White,
                    Background = Brushes.Transparent,
                    Padding = new Thickness(8)
                });
            }
        }

        refresh.Click += async (_, _) =>
        {
            try { await Reload(); }
            catch (Exception ex) { ShowToast("INVITES: " + ex.Message); }
        };

        create.Click += async (_, _) =>
        {
            try
            {
                var invite = await api.CreateInviteAsync(3600, 1);
                tokenBox.Text = invite.Token ?? "";
                await Reload();
                ShowToast("INVITE СОЗДАН · TOKEN В ПОЛЕ");
            }
            catch (Exception ex) { ShowToast("INVITE: " + ex.Message); }
        };

        redeem.Click += async (_, _) =>
        {
            var token = tokenBox.Text.Trim();
            if (token.Length == 0) { ShowToast("ВСТАВЬ INVITE TOKEN"); return; }

            try
            {
                var card = await api.RedeemInviteAsync(token);
                IdentityCrypto.Validate(card);
                var contact = state.Contacts.FirstOrDefault(x => x.Card.Id == card.Id);
                if (contact == null)
                {
                    contact = new ContactState
                    {
                        Card = card,
                        Name = "Ghost " + card.Id[..Math.Min(6, card.Id.Length)].ToUpperInvariant()
                    };
                    state.Contacts.Add(contact);
                }
                else
                {
                    contact.Card = card;
                }

                Save();
                RefreshPeople();
                RefreshCollections();
                ShowToast("КОНТАКТ ДОБАВЛЕН ПО INVITE");
                tokenBox.Clear();
            }
            catch (Exception ex) { ShowToast("INVITE: " + ex.Message); }
        };

        revoke.Click += async (_, _) =>
        {
            if (list.SelectedItem is not ListBoxItem item || item.Tag is not Vo1dApi.InviteReceiptDto invite)
            {
                ShowToast("ВЫБЕРИ INVITE");
                return;
            }

            try
            {
                await api.RevokeInviteAsync(invite.Id);
                await Reload();
                ShowToast("INVITE ОТОЗВАН");
            }
            catch (Exception ex) { ShowToast("INVITE: " + ex.Message); }
        };

        try { await Reload(); }
        catch (Exception ex) { ShowToast("INVITES: " + ex.Message); }

        win.ShowDialog();
    }

    private async void ManageRelaySessions_Click(object sender, RoutedEventArgs e)
    {
        var list = new ListBox
        {
            Background = Brushes.Transparent,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 12, 0, 12),
            MinHeight = 220
        };

        var refresh = ActionButton("ОБНОВИТЬ");
        var revoke = ActionButton("ЗАВЕРШИТЬ ОСТАЛЬНЫЕ");
        refresh.Margin = new Thickness(0, 0, 8, 8);
        revoke.Margin = new Thickness(0, 0, 8, 8);

        var buttons = new WrapPanel();
        buttons.Children.Add(refresh);
        buttons.Children.Add(revoke);

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = "Сессии relay", FontSize = 26, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock
        {
            Text = "Отзыв сессии отключает bearer-сессию, но не отменяет уже украденную копию приватных ключей.",
            Foreground = Brushes.Gray,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0)
        });
        panel.Children.Add(buttons);
        panel.Children.Add(list);

        var win = PopupWindow("Relay sessions", panel, 610, 540);

        async Task Reload()
        {
            list.Items.Clear();
            var sessions = await api.ListSessionsAsync();
            foreach (var session in sessions.OrderByDescending(x => x.Current).ThenByDescending(x => x.ExpiresAt))
            {
                var expires = DateTimeOffset.FromUnixTimeSeconds(session.ExpiresAt).LocalDateTime.ToString("dd.MM.yyyy HH:mm");
                list.Items.Add(new ListBoxItem
                {
                    Content = $"{(session.Current ? "ЭТА СЕССИЯ" : "ДРУГАЯ")} · {session.Id} · до {expires}",
                    Foreground = Brushes.White,
                    Background = Brushes.Transparent,
                    Padding = new Thickness(8)
                });
            }
        }

        refresh.Click += async (_, _) =>
        {
            try { await Reload(); }
            catch (Exception ex) { ShowToast("SESSIONS: " + ex.Message); }
        };

        revoke.Click += async (_, _) =>
        {
            try
            {
                await api.RevokeOtherSessionsAsync();
                await Reload();
                ShowToast("ОСТАЛЬНЫЕ СЕССИИ ЗАВЕРШЕНЫ");
            }
            catch (Exception ex) { ShowToast("SESSIONS: " + ex.Message); }
        };

        try { await Reload(); }
        catch (Exception ex) { ShowToast("SESSIONS: " + ex.Message); }

        win.ShowDialog();
    }

    private async void ShowRelayStorage_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var storage = await api.StorageAsync();
            var panel = new StackPanel { Margin = new Thickness(22) };
            panel.Children.Add(new TextBlock { Text = "Relay storage", FontSize = 26, FontWeight = FontWeights.Black });
            panel.Children.Add(StorageMetric("В очереди", storage.QueuedMessages.ToString()));
            panel.Children.Add(StorageMetric("Mailbox", FormatBytes(storage.MailboxBytes)));
            panel.Children.Add(StorageMetric("Файлов", storage.Files.ToString()));
            panel.Children.Add(StorageMetric("Файлы", FormatBytes(storage.FileBytes)));
            panel.Children.Add(new TextBlock
            {
                Text = "Это серверные зашифрованные данные и очередь; локальный vault считается отдельно.",
                Foreground = Brushes.Gray,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 16, 0, 0)
            });
            PopupWindow("Relay storage", panel, 500, 420).ShowDialog();
        }
        catch (Exception ex)
        {
            ShowToast("STORAGE: " + ex.Message);
        }
    }

    private static Border StorageMetric(string title, string value)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = title, Foreground = Brushes.Gray, Margin = new Thickness(0, 5, 18, 5) });
        var right = new TextBlock { Text = value, Foreground = Brushes.White, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 5, 0, 5) };
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);

        return new Border
        {
            Child = grid,
            Padding = new Thickness(12, 7, 12, 7),
            Margin = new Thickness(0, 8, 0, 0),
            CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(24, 255, 255, 255)),
            BorderThickness = new Thickness(1)
        };
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return bytes + " B";
        if (bytes < 1024L * 1024L) return (bytes / 1024d).ToString("0.0") + " KB";
        if (bytes < 1024L * 1024L * 1024L) return (bytes / 1024d / 1024d).ToString("0.0") + " MB";
        return (bytes / 1024d / 1024d / 1024d).ToString("0.00") + " GB";
    }
}
