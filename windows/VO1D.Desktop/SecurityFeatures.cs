using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace VO1D.Desktop;

public partial class MainWindow
{
    private bool sessionUnlocked;

    private string HashLockPin(string pin)
    {
        var owner = crypto?.Card.Id ?? "";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("VO1D-PIN-1\n" + owner + "\n" + pin)))
            .ToLowerInvariant();
    }

    private void SetPin_Click(object sender, RoutedEventArgs e)
    {
        var pin = PromptSecret("PIN VO1D", "Введи новый PIN (4–8 цифр)", confirm: true);
        if (pin == null) return;
        if (pin.Length is < 4 or > 8 || pin.Any(ch => !char.IsDigit(ch)))
        {
            ShowToast("PIN: ТОЛЬКО 4–8 ЦИФР");
            return;
        }

        state.LockPinHash = HashLockPin(pin);
        state.AppLock = true;
        sessionUnlocked = true;
        Save();
        UpdateSecurityUi();
        ShowToast("PIN-ЗАЩИТА ВКЛЮЧЕНА");
    }

    private void DisablePin_Click(object sender, RoutedEventArgs e)
    {
        if (!state.AppLock)
        {
            ShowToast("PIN-ЗАЩИТА УЖЕ ВЫКЛЮЧЕНА");
            return;
        }

        var pin = PromptSecret("Отключить PIN", "Подтверди текущий PIN");
        if (pin == null) return;
        if (!CryptographicOperations.FixedTimeEquals(
                Encoding.ASCII.GetBytes(HashLockPin(pin)),
                Encoding.ASCII.GetBytes(state.LockPinHash ?? "")))
        {
            ShowToast("НЕВЕРНЫЙ PIN");
            return;
        }

        state.AppLock = false;
        state.LockPinHash = null;
        sessionUnlocked = true;
        Save();
        UpdateSecurityUi();
        ShowToast("PIN-ЗАЩИТА ВЫКЛЮЧЕНА");
    }

    private void LockNow_Click(object sender, RoutedEventArgs e)
    {
        if (!state.AppLock || string.IsNullOrWhiteSpace(state.LockPinHash))
        {
            ShowToast("СНАЧАЛА УСТАНОВИ PIN");
            return;
        }
        LockSession();
    }

    private void LockSession()
    {
        poll.Stop();
        VoiceCleanup();
        try { signal?.Dispose(); } catch { }
        try { api?.Dispose(); } catch { }
        signal = null;
        api = null!;
        sessionUnlocked = false;
        LockPinBox.Clear();
        LockError.Visibility = Visibility.Collapsed;
        LockLayer.Visibility = Visibility.Visible;
        LockLayer.Opacity = 0;
        LockLayer.BeginAnimation(OpacityProperty,
            new System.Windows.Media.Animation.DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
        LockPinBox.Focus();
    }

    private async void Unlock_Click(object sender, RoutedEventArgs e)
    {
        var pin = LockPinBox.Password;
        var expected = state.LockPinHash ?? "";
        var actual = HashLockPin(pin);
        if (expected.Length == 0 ||
            expected.Length != actual.Length ||
            !CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(expected), Encoding.ASCII.GetBytes(actual)))
        {
            LockError.Text = "Неверный PIN";
            LockError.Visibility = Visibility.Visible;
            LockPinBox.SelectAll();
            return;
        }

        sessionUnlocked = true;
        LockError.Visibility = Visibility.Collapsed;
        LockLayer.Visibility = Visibility.Collapsed;

        try
        {
            signal?.Dispose();
            api?.Dispose();
            crypto?.Dispose();
        }
        catch { }

        await BootAsync();
    }

    private void LockPin_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter) Unlock_Click(UnlockButton, new RoutedEventArgs());
    }

    private void UpdateSecurityUi()
    {
        if (SecurityStatus == null) return;
        SecurityStatus.Text = state.AppLock ? "PIN-LOCK · ВКЛЮЧЁН" : "PIN-LOCK · ВЫКЛЮЧЕН";
        SecurityStatus.Foreground = new SolidColorBrush(state.AppLock
            ? Color.FromArgb(220, 255, 255, 255)
            : Color.FromArgb(120, 255, 255, 255));
    }

    private void ExportBackup_Click(object sender, RoutedEventArgs e)
    {
        var password = PromptSecret("Backup VO1D", "Пароль для зашифрованной резервной копии", confirm: true);
        if (password == null) return;
        if (password.Length < 8)
        {
            ShowToast("ПАРОЛЬ BACKUP: МИНИМУМ 8 СИМВОЛОВ");
            return;
        }

        var dialog = new SaveFileDialog
        {
            Title = "Экспорт VO1D backup",
            Filter = "VO1D encrypted backup|*.vo1dbackup",
            FileName = "VO1D-" + DateTime.Now.ToString("yyyy-MM-dd-HHmm") + ".vo1dbackup",
            AddExtension = true,
            DefaultExt = ".vo1dbackup"
        };
        if (dialog.ShowDialog(this) != true) return;

        try
        {
            Save();
            var package = new BackupPackage
            {
                Version = 2,
                ExportedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                Identity = crypto.Raw,
                State = state
            };
            var clear = JsonSerializer.SerializeToUtf8Bytes(package, AppJson.Options);
            var blob = EncryptBackup(clear, password);
            File.WriteAllBytes(dialog.FileName, blob);
            CryptographicOperations.ZeroMemory(clear);
            ShowToast("BACKUP ЗАШИФРОВАН И СОХРАНЁН");
        }
        catch (Exception ex)
        {
            ShowToast("BACKUP: " + ex.Message);
        }
    }

    private void ImportBackup_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Импорт VO1D backup",
            Filter = "VO1D encrypted backup|*.vo1dbackup|Все файлы|*.*",
            Multiselect = false
        };
        if (dialog.ShowDialog(this) != true) return;

        var password = PromptSecret("Импорт VO1D", "Пароль от резервной копии");
        if (password == null) return;

        try
        {
            var clear = DecryptBackup(File.ReadAllBytes(dialog.FileName), password);
            var package = JsonSerializer.Deserialize<BackupPackage>(clear, AppJson.Options)
                          ?? throw new InvalidDataException("Backup не читается.");
            CryptographicOperations.ZeroMemory(clear);

            if (package.Version != 2 || package.Identity == null || package.State == null)
                throw new InvalidDataException("Неподдерживаемая версия backup.");

            // Validate signing/agreement material before replacing the live profile.
            using (var verify = new IdentityCrypto(package.Identity))
                _ = verify.Card;

            var answer = MessageBox.Show(
                this,
                "Текущий локальный профиль будет заменён данными из backup. Продолжить?",
                "VO1D · Import",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (answer != MessageBoxResult.Yes) return;

            disk.ReplaceIdentityAndVault(package.Identity, package.State);
            RestartApplication();
        }
        catch (CryptographicException)
        {
            ShowToast("BACKUP: НЕВЕРНЫЙ ПАРОЛЬ ИЛИ ФАЙЛ ПОВРЕЖДЁН");
        }
        catch (Exception ex)
        {
            ShowToast("BACKUP: " + ex.Message);
        }
    }

    private static byte[] EncryptBackup(byte[] clear, string password)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var key = Rfc2898DeriveBytes.Pbkdf2(
            password,
            salt,
            250_000,
            HashAlgorithmName.SHA256,
            32);

        var cipher = new byte[clear.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(key, 16))
            aes.Encrypt(nonce, clear, cipher, tag, BackupMagic);

        var result = new byte[BackupMagic.Length + salt.Length + nonce.Length + tag.Length + cipher.Length];
        var offset = 0;
        Buffer.BlockCopy(BackupMagic, 0, result, offset, BackupMagic.Length); offset += BackupMagic.Length;
        Buffer.BlockCopy(salt, 0, result, offset, salt.Length); offset += salt.Length;
        Buffer.BlockCopy(nonce, 0, result, offset, nonce.Length); offset += nonce.Length;
        Buffer.BlockCopy(tag, 0, result, offset, tag.Length); offset += tag.Length;
        Buffer.BlockCopy(cipher, 0, result, offset, cipher.Length);
        CryptographicOperations.ZeroMemory(key);
        return result;
    }

    private static byte[] DecryptBackup(byte[] blob, string password)
    {
        var min = BackupMagic.Length + 16 + 12 + 16;
        if (blob.Length <= min || !blob.AsSpan(0, BackupMagic.Length).SequenceEqual(BackupMagic))
            throw new InvalidDataException("Это не VO1D backup v2.");

        var offset = BackupMagic.Length;
        var salt = blob.AsSpan(offset, 16).ToArray(); offset += 16;
        var nonce = blob.AsSpan(offset, 12).ToArray(); offset += 12;
        var tag = blob.AsSpan(offset, 16).ToArray(); offset += 16;
        var cipher = blob.AsSpan(offset).ToArray();
        var clear = new byte[cipher.Length];

        var key = Rfc2898DeriveBytes.Pbkdf2(
            password,
            salt,
            250_000,
            HashAlgorithmName.SHA256,
            32);
        try
        {
            using var aes = new AesGcm(key, 16);
            aes.Decrypt(nonce, cipher, tag, clear, BackupMagic);
            return clear;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }
    }

    private string? PromptSecret(string title, string prompt, bool confirm = false)
    {
        string? result = null;
        var first = new PasswordBox
        {
            Margin = new Thickness(0, 10, 0, 8),
            Padding = new Thickness(12),
            FontSize = 16
        };
        var second = new PasswordBox
        {
            Margin = new Thickness(0, 0, 0, 12),
            Padding = new Thickness(12),
            FontSize = 16,
            Visibility = confirm ? Visibility.Visible : Visibility.Collapsed
        };
        var error = new TextBlock
        {
            Foreground = Brushes.White,
            Opacity = .72,
            Margin = new Thickness(0, 0, 0, 10),
            Visibility = Visibility.Collapsed
        };
        var ok = new Button
        {
            Content = "ПОДТВЕРДИТЬ",
            Height = 44,
            Background = Brushes.White,
            Foreground = Brushes.Black,
            BorderThickness = new Thickness(0),
            FontWeight = FontWeights.Bold
        };

        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 24, FontWeight = FontWeights.Black });
        panel.Children.Add(new TextBlock { Text = prompt, Foreground = Brushes.Gray, Margin = new Thickness(0, 8, 0, 0), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(first);
        if (confirm)
        {
            panel.Children.Add(new TextBlock { Text = "Повтори", Foreground = Brushes.Gray });
            panel.Children.Add(second);
        }
        panel.Children.Add(error);
        panel.Children.Add(ok);

        var win = PopupWindow(title, panel, 420, confirm ? 390 : 330);
        ok.Click += (_, _) =>
        {
            if (string.IsNullOrEmpty(first.Password))
            {
                error.Text = "Поле пустое.";
                error.Visibility = Visibility.Visible;
                return;
            }
            if (confirm && first.Password != second.Password)
            {
                error.Text = "Значения не совпадают.";
                error.Visibility = Visibility.Visible;
                return;
            }
            result = first.Password;
            win.DialogResult = true;
        };
        first.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter && !confirm) ok.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        };
        first.Focus();
        win.ShowDialog();
        return result;
    }

    private static void RestartApplication()
    {
        var path = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(path))
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        Application.Current.Shutdown();
    }

    private static readonly byte[] BackupMagic = Encoding.ASCII.GetBytes("VO1DBAK2");

    private sealed class BackupPackage
    {
        public int Version { get; set; }
        public long ExportedAt { get; set; }
        public LocalIdentity? Identity { get; set; }
        public VaultState? State { get; set; }
    }
}
