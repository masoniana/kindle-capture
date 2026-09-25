using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Kindle Capture")]
[assembly: AssemblyDescription("Self-contained Kindle Capture application")]
[assembly: AssemblyCompany("KindleCapture")]
[assembly: AssemblyProduct("Kindle Capture")]
[assembly: AssemblyVersion("2.4.2.0")]
[assembly: AssemblyFileVersion("2.4.2.0")]

internal static class Program
{
    private const string AppVersion = "2.4.2";
    private const string GuiResource = "KindleCapture.GuiScript";
    private const string CoreResource = "KindleCapture.CoreScript";

    [STAThread]
    private static void Main(string[] args)
    {
        try
        {
            bool smokeTest = Array.Exists(args ?? new string[0], value => string.Equals(value, "--smoke-test", StringComparison.OrdinalIgnoreCase));
            string cacheDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "KindleCapture",
                AppVersion
            );
            Directory.CreateDirectory(cacheDirectory);

            string guiScript = Path.Combine(cacheDirectory, "KindleCapture-GUI.ps1");
            string coreScript = Path.Combine(cacheDirectory, "KindleCapture-Core.ps1");
            ExtractEmbeddedFile(GuiResource, guiScript);
            ExtractEmbeddedFile(CoreResource, coreScript);

            string powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe"
            );
            if (!File.Exists(powerShell))
            {
                throw new FileNotFoundException("Windows PowerShell が見つかりません。", powerShell);
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = powerShell,
                Arguments = "-NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + guiScript + "\"" + (smokeTest ? " -SmokeTest" : ""),
                WorkingDirectory = cacheDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process process = Process.Start(startInfo);
            if (process == null)
            {
                throw new InvalidOperationException("PowerShellプロセスを開始できませんでした。");
            }
            if (smokeTest)
            {
                process.WaitForExit();
                Environment.ExitCode = process.ExitCode;
            }
            process.Dispose();
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "Kindle Capture を起動できませんでした。\r\n\r\n" + exception.Message,
                "Kindle Capture",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
        }
    }

    private static void ExtractEmbeddedFile(string resourceName, string destinationPath)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        using (Stream input = assembly.GetManifestResourceStream(resourceName))
        {
            if (input == null)
            {
                throw new InvalidOperationException("内蔵ファイルを読み込めません: " + resourceName);
            }

            string temporaryPath = destinationPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            string backupPath = destinationPath + ".previous";
            try
            {
                using (var output = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    input.CopyTo(output);
                    output.Flush(true);
                }

                if (File.Exists(destinationPath))
                {
                    if (File.Exists(backupPath))
                    {
                        File.Delete(backupPath);
                    }
                    File.Replace(temporaryPath, destinationPath, backupPath, true);
                    if (File.Exists(backupPath))
                    {
                        File.Delete(backupPath);
                    }
                }
                else
                {
                    File.Move(temporaryPath, destinationPath);
                }
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
        }
    }
}
