// Single-file setup: unpacks the embedded installer to a new temporary folder, runs it, then cleans up.
// Built by Build-Exe.ps1 with the C# compiler that ships with Windows (C# 5).
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("pyRevit MCP for Claude - Setup")]
[assembly: AssemblyProduct("pyRevit MCP for Claude")]
[assembly: AssemblyCompany("Tay Zar")]
[assembly: AssemblyCopyright("Installer by Tay Zar. Bundled software keeps its own licenses.")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

static class Launcher
{
    // Load Windows DLLs from System32 only, not from the folder the EXE was downloaded to.
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetDefaultDllDirectories(uint flags);

    const string Title = "pyRevit MCP Setup";

    [STAThread]
    static int Main(string[] args)
    {
        SetDefaultDllDirectories(0x00000800);
        bool first;
        using (new Mutex(true, "Local\\PyRevitMcpSetup", out first))
        {
            if (!first) { Show("Setup is already running."); return 2; }
            Application.EnableVisualStyles();
            string folder = Path.Combine(Path.GetTempPath(), "PyRevitMCP-Setup-" + Guid.NewGuid().ToString("N"));
            try
            {
                if (!Unpack(folder)) return 1;
                return Run(folder, Has(args, "/uninstall"), Has(args, "/nosplash"));
            }
            catch (Exception ex) { Show("Setup could not start.\r\n\r\n" + ex.Message); return 1; }
            finally { Delete(folder); }
        }
    }

    static bool Has(string[] args, string name)
    {
        foreach (string a in args) if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    static void Show(string text) { MessageBox.Show(text, Title, MessageBoxButtons.OK, MessageBoxIcon.Warning); }

    static bool Unpack(string folder)
    {
        Exception failure = null;
        var form = new Form { Text = Title, Width = 420, Height = 130, FormBorderStyle = FormBorderStyle.FixedDialog,
                              MaximizeBox = false, MinimizeBox = false, ControlBox = false, StartPosition = FormStartPosition.CenterScreen };
        form.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        form.Controls.Add(new Label { Text = "Preparing files, please wait...", Left = 20, Top = 15, Width = 370 });
        var bar = new ProgressBar { Left = 20, Top = 45, Width = 365, Height = 20, Maximum = 1000 };
        form.Controls.Add(bar);
        var worker = new Thread(delegate()
        {
            try
            {
                Directory.CreateDirectory(folder);
                string root = Path.GetFullPath(folder) + Path.DirectorySeparatorChar;
                using (Stream data = Assembly.GetExecutingAssembly().GetManifestResourceStream("setup.zip"))
                using (var zip = new ZipArchive(data, ZipArchiveMode.Read))
                {
                    long total = 0, done = 0; int shown = 0;
                    foreach (var e in zip.Entries) total += e.Length;
                    var buffer = new byte[1 << 20];
                    foreach (var e in zip.Entries)
                    {
                        string target = Path.GetFullPath(Path.Combine(root, e.FullName));
                        if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unsafe path in package.");
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        using (Stream from = e.Open())
                        using (var to = new FileStream(target, FileMode.CreateNew))
                        {
                            int n;
                            while ((n = from.Read(buffer, 0, buffer.Length)) > 0)
                            {
                                to.Write(buffer, 0, n); done += n;
                                int now = (int)(done * 1000 / Math.Max(1, total));
                                if (now != shown) { shown = now; form.BeginInvoke((Action)delegate { bar.Value = Math.Min(1000, now); }); }
                            }
                        }
                    }
                }
            }
            catch (Exception ex) { failure = ex; }
            form.BeginInvoke((Action)delegate { form.Close(); });
        });
        form.Shown += delegate { worker.Start(); };
        Application.Run(form);
        worker.Join();
        if (failure != null) { Show("Could not unpack the setup files.\r\n\r\n" + failure.Message); return false; }
        return true;
    }

    static int Run(string folder, bool uninstall, bool noSplash)
    {
        var info = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell\\v1.0\\powershell.exe"),
            Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + Path.Combine(folder, "Installer.ps1") + "\""
                        + (uninstall ? " -Uninstall" : "") + (noSplash ? " -NoSplash" : ""),
            WorkingDirectory = folder, UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true
        };
        // A PowerShell 7 module path inherited from the caller breaks Windows PowerShell.
        info.EnvironmentVariables.Remove("PSModulePath");
        using (Process p = Process.Start(info))
        {
            var errors = new StringBuilder();
            p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) errors.AppendLine(e.Data); };
            p.BeginErrorReadLine();
            p.WaitForExit();
            if (p.ExitCode != 0)
            {
                string text = errors.ToString();
                Show("Setup stopped with an error.\r\n\r\n" + (text.Length > 1500 ? text.Substring(0, 1500) : text));
            }
            return p.ExitCode;
        }
    }

    static void Delete(string folder)
    {
        for (int i = 0; i < 10 && Directory.Exists(folder); i++)
        {
            try { Directory.Delete(folder, true); }
            catch (IOException) { Thread.Sleep(500); }
            catch (UnauthorizedAccessException) { Thread.Sleep(500); }
        }
    }
}
