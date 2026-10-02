using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;

namespace VO1D.Desktop;

public partial class App : Application
{
    public static string CrashLogPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VO1D", "crash.log");

    public App()
    {
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
    }

    private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        WriteCrash("DispatcherUnhandledException", e.Exception);
        // Keep the default crash behavior so CI catches the problem.
        e.Handled = false;
    }

    private static void OnDomainUnhandledException(object? sender, UnhandledExceptionEventArgs e)
    {
        WriteCrash("AppDomain.UnhandledException", e.ExceptionObject as Exception ??
            new Exception("Non-Exception unhandled object: " + e.ExceptionObject));
    }

    private static void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        WriteCrash("TaskScheduler.UnobservedTaskException", e.Exception);
    }

    private static void WriteCrash(string source, Exception exception)
    {
        try
        {
            var dir = Path.GetDirectoryName(CrashLogPath)!;
            Directory.CreateDirectory(dir);
            var text = new StringBuilder()
                .AppendLine("=== VO1D WINDOWS CRASH ===")
                .AppendLine(DateTimeOffset.UtcNow.ToString("O"))
                .AppendLine(source)
                .AppendLine(exception.ToString())
                .AppendLine()
                .ToString();
            File.AppendAllText(CrashLogPath, text, Encoding.UTF8);
        }
        catch
        {
            // Crash logging must never hide the original exception.
        }
    }
}
