using NAudio.Wave;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace VO1D.Desktop;

public partial class MainWindow
{
    private WaveInEvent? voiceInput;
    private WaveFileWriter? voiceWriter;
    private string? voiceTempPath;
    private DateTimeOffset voiceStartedAt;
    private WaveOutEvent? voiceOutput;
    private WaveFileReader? voicePlaybackReader;
    private MemoryStream? voicePlaybackStream;

    private void Voice_Click(object sender, RoutedEventArgs e)
    {
        if (selectedRoom == null) return;

        if (voiceInput != null)
        {
            StopVoiceRecording();
            return;
        }

        try
        {
            voiceTempPath = Path.Combine(Path.GetTempPath(), "vo1d-voice-" + Guid.NewGuid().ToString("N") + ".wav");
            voiceInput = new WaveInEvent
            {
                WaveFormat = new WaveFormat(16000, 16, 1),
                BufferMilliseconds = 80,
                NumberOfBuffers = 3
            };
            voiceWriter = new WaveFileWriter(voiceTempPath, voiceInput.WaveFormat);
            voiceInput.DataAvailable += VoiceInput_DataAvailable;
            voiceInput.RecordingStopped += VoiceInput_RecordingStopped;
            voiceStartedAt = DateTimeOffset.UtcNow;
            voiceInput.StartRecording();

            VoiceButton.Content = "■";
            VoiceButton.ToolTip = "Остановить запись";
            PendingAttachmentText.Text = "Запись голосового…";
            PendingAttachmentText.Visibility = Visibility.Visible;
            ShowToast("ЗАПИСЬ ГОЛОСОВОГО");
        }
        catch (Exception ex)
        {
            CleanupVoiceRecorder();
            ShowToast("МИКРОФОН: " + ex.Message);
        }
    }

    private void VoiceInput_DataAvailable(object? sender, WaveInEventArgs e)
    {
        try
        {
            voiceWriter?.Write(e.Buffer, 0, e.BytesRecorded);
            voiceWriter?.Flush();
            if (DateTimeOffset.UtcNow - voiceStartedAt >= TimeSpan.FromMinutes(5))
                Dispatcher.Invoke(StopVoiceRecording);
        }
        catch { }
    }

    private void StopVoiceRecording()
    {
        try { voiceInput?.StopRecording(); }
        catch { CleanupVoiceRecorder(); }
    }

    private void VoiceInput_RecordingStopped(object? sender, StoppedEventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            try
            {
                voiceWriter?.Dispose();
                voiceWriter = null;
                voiceInput?.Dispose();
                voiceInput = null;

                if (e.Exception != null) throw e.Exception;
                if (voiceTempPath == null || !File.Exists(voiceTempPath)) throw new InvalidDataException("Запись не создана.");

                var data = File.ReadAllBytes(voiceTempPath);
                if (data.Length < 1280)
                {
                    PendingAttachmentText.Visibility = Visibility.Collapsed;
                    ShowToast("ГОЛОСОВОЕ СЛИШКОМ КОРОТКОЕ");
                    return;
                }

                pendingAttachment = new AttachmentState
                {
                    Name = "voice-" + DateTimeOffset.Now.ToString("yyyyMMdd-HHmmss") + ".wav",
                    Mime = "audio/wav",
                    Data = data
                };
                var duration = Math.Max(1, (int)(DateTimeOffset.UtcNow - voiceStartedAt).TotalSeconds);
                PendingAttachmentText.Text = $"Голосовое · {duration} сек";
                PendingAttachmentText.Visibility = Visibility.Visible;
            }
            catch (Exception ex)
            {
                pendingAttachment = null;
                PendingAttachmentText.Visibility = Visibility.Collapsed;
                ShowToast("ГОЛОСОВОЕ: " + ex.Message);
            }
            finally
            {
                VoiceButton.Content = "\uE720";
                VoiceButton.ToolTip = "Голосовое";
                DeleteVoiceTemp();
            }
        });
    }

    private void MessageAttachment_Click(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not MessageVm vm ||
            vm.Source.Attachment is not { } attachment ||
            attachment.Data.Length == 0) return;

        if (attachment.Mime.StartsWith("audio/", StringComparison.OrdinalIgnoreCase))
        {
            PlayVoiceAttachment(attachment);
            return;
        }

        var dialog = new SaveFileDialog
        {
            FileName = attachment.Name,
            Title = "Сохранить вложение VO1D"
        };
        if (dialog.ShowDialog(this) == true)
        {
            try
            {
                File.WriteAllBytes(dialog.FileName, attachment.Data);
                ShowToast("ВЛОЖЕНИЕ СОХРАНЕНО");
            }
            catch (Exception ex) { ShowToast(ex.Message); }
        }
    }

    private void PlayVoiceAttachment(AttachmentState attachment)
    {
        try
        {
            StopVoicePlayback();
            voicePlaybackStream = new MemoryStream(attachment.Data, writable: false);
            voicePlaybackReader = new WaveFileReader(voicePlaybackStream);
            voiceOutput = new WaveOutEvent();
            voiceOutput.Init(voicePlaybackReader);
            voiceOutput.PlaybackStopped += (_, _) => Dispatcher.Invoke(StopVoicePlayback);
            voiceOutput.Play();
            ShowToast("ВОСПРОИЗВЕДЕНИЕ ГОЛОСОВОГО");
        }
        catch (Exception ex)
        {
            StopVoicePlayback();
            ShowToast("АУДИО: " + ex.Message);
        }
    }

    private void StopVoicePlayback()
    {
        try { voiceOutput?.Stop(); } catch { }
        try { voiceOutput?.Dispose(); } catch { }
        try { voicePlaybackReader?.Dispose(); } catch { }
        try { voicePlaybackStream?.Dispose(); } catch { }
        voiceOutput = null;
        voicePlaybackReader = null;
        voicePlaybackStream = null;
    }

    private void CleanupVoiceRecorder()
    {
        try { voiceInput?.StopRecording(); } catch { }
        try { voiceInput?.Dispose(); } catch { }
        try { voiceWriter?.Dispose(); } catch { }
        voiceInput = null;
        voiceWriter = null;
        VoiceButton.Content = "\uE720";
        VoiceButton.ToolTip = "Голосовое";
        DeleteVoiceTemp();
    }

    private void DeleteVoiceTemp()
    {
        if (voiceTempPath != null)
        {
            try { if (File.Exists(voiceTempPath)) File.Delete(voiceTempPath); } catch { }
        }
        voiceTempPath = null;
    }

    private void VoiceCleanup()
    {
        CleanupVoiceRecorder();
        StopVoicePlayback();
    }
}
