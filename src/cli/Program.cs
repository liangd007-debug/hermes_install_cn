using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace HermesInstallCn
{
    /// <summary>
    /// hermes-install-cn.exe —— 命令行版启动器。
    /// 内嵌项目根的 install-cn.ps1（编译期由 build.ps1 以 /resource 嵌入），
    /// 运行时解到 %TEMP% 后以 powershell -ExecutionPolicy Bypass 执行，
    /// 参数原样透传（-Proxy / -Persist / -NoDesktop），退出码回传。
    /// --selftest：只解包+打印指纹，不安装，用于验证产物完整性。
    /// </summary>
    internal static class Program
    {
        private const string ResourceName = "hermes_install_cn.installer.ps1";

        // ---- 控制台 VT 能力：打开后 uv/npm 的进度改走 ANSI 整行擦除，
        //      不再用"回车+空格"土法重绘（窄窗口换行后留残帧 = 用户看到的叠字） ----
        private const int StdOutputHandle = -11;
        private const uint EnableVirtualTerminalProcessing = 0x0004;

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        // ---- 窗口尺寸写死：去掉可调边框与最大化按钮 + 宽度钉 120 列；退出时还原样式 ----
        private const int GwlStyle = -16;
        private const int WsThickFrame = 0x00040000;
        private const int WsMaximizeBox = 0x00010000;
        private const int SwRestore = 9;
        private const short FixedWidth = 130;
        private static int _savedStyle;

        // 注意：GetConsoleWindow 在 kernel32（容易和 user32 的窗口族函数记混，写错即 EntryPointNotFound）
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool IsZoomed(IntPtr hWnd);

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct Coord { public short X; public short Y; }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct SmallRect { public short Left; public short Top; public short Right; public short Bottom; }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct ConsoleScreenBufferInfo
        {
            public Coord dwSize;
            public Coord dwCursorPosition;
            public short wAttributes;
            public SmallRect srWindow;
            public Coord dwMaximumWindowSize;
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleScreenBufferInfo(IntPtr h, out ConsoleScreenBufferInfo info);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleScreenBufferSize(IntPtr h, Coord sz);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleWindowInfo(IntPtr h, bool absolute, ref SmallRect rect);

        /// <summary>锁布局：退出最大化 → 剥离 WS_THICKFRAME/WS_MAXIMIZEBOX（保留最小化和关闭）
        /// → 宽度钉死 120 列。高度保持用户现状。</summary>
        private static void LockConsoleLayout(IntPtr hCon)
        {
            IntPtr hw = GetConsoleWindow();
            if (hw == IntPtr.Zero) return;
            try
            {
                if (IsZoomed(hw)) ShowWindow(hw, SwRestore);
                _savedStyle = GetWindowLong(hw, GwlStyle);
                SetWindowLong(hw, GwlStyle, _savedStyle & ~(WsThickFrame | WsMaximizeBox));
            }
            catch { }
            try
            {
                ConsoleScreenBufferInfo info;
                if (!GetConsoleScreenBufferInfo(hCon, out info)) return;
                if (info.dwSize.X > FixedWidth)
                {
                    // 先缩窗口再缩缓冲（窗口永远不得超过缓冲）
                    SmallRect rw = info.srWindow;
                    rw.Left = 0; rw.Right = (short)(FixedWidth - 1);
                    SetConsoleWindowInfo(hCon, true, ref rw);
                    SetConsoleScreenBufferSize(hCon, new Coord { X = FixedWidth, Y = info.dwSize.Y });
                }
                else if (info.dwSize.X < FixedWidth)
                {
                    SetConsoleScreenBufferSize(hCon, new Coord { X = FixedWidth, Y = info.dwSize.Y });
                }
                ConsoleScreenBufferInfo cur;
                if (GetConsoleScreenBufferInfo(hCon, out cur))
                {
                    SmallRect rf = cur.srWindow;
                    rf.Left = 0; rf.Right = (short)(FixedWidth - 1);
                    SetConsoleWindowInfo(hCon, true, ref rf);
                }
            }
            catch { }
        }

        /// <summary>退出时把"可拉伸/可最大化"还给用户窗口（宽度保持120不再折腾）。</summary>
        private static void UnlockConsoleStyle()
        {
            if (_savedStyle == 0) return;
            IntPtr hw = GetConsoleWindow();
            if (hw != IntPtr.Zero)
            {
                try { SetWindowLong(hw, GwlStyle, _savedStyle); } catch { }
            }
            _savedStyle = 0;
        }

        private static int Main(string[] args)
        {
            string script = Path.Combine(Path.GetTempPath(), "hermes-install-cn.ps1");

            if (args.Length == 1 &&
                (args[0].Equals("--selftest", StringComparison.OrdinalIgnoreCase) ||
                 args[0].Equals("-SelfTest", StringComparison.OrdinalIgnoreCase)))
            {
                byte[] data = ReadEmbedded();
                File.WriteAllBytes(script, data);
                Console.WriteLine("Hermes Install CN - CLI launcher selftest");
                Console.WriteLine("  embedded : " + data.Length + " bytes");
                Console.WriteLine("  sha256   : " + Sha256Hex(data));
                Console.WriteLine("  extracted: " + script);
                Console.WriteLine("  RESULT   : OK");
                return 0;
            }

            // 正常安装：解出脚本 → 本控制台直接跑（UseShellExecute=false 继承控制台，输出原样滚动）
            File.WriteAllBytes(script, ReadEmbedded());

            // 控制台预处理（记录现场，子进程结束后还原）：
            //  1) 打开 VT —— 进度工具走 ANSI 整行擦除，根治回车重绘残帧叠字
            //  2) UTF-8 从第 1 行生效 —— 原来脚本到 [5/5] 才切，前四段是 GBK 窗口
            IntPtr hCon = GetStdHandle(StdOutputHandle);
            uint oldMode = 0;
            bool modeOk = GetConsoleMode(hCon, out oldMode);
            if (modeOk) { try { SetConsoleMode(hCon, oldMode | EnableVirtualTerminalProcessing); } catch { } }
            int origCodePage = -1;
            try { origCodePage = Console.OutputEncoding.CodePage; } catch { }
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
            LockConsoleLayout(hCon);   // 尺寸写死：安装全程拖不动、最大化不可用

            StringBuilder forwarded = new StringBuilder();
            foreach (string a in args)
            {
                forwarded.Append(Quote(a));
                forwarded.Append(' ');
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(script)
                + (forwarded.Length > 0 ? " " + forwarded.ToString().TrimEnd() : string.Empty);
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Environment.CurrentDirectory;

            int code = 1;
            try
            {
                using (Process p = Process.Start(psi))
                {
                    if (p != null)
                    {
                        p.WaitForExit();
                        code = p.ExitCode;
                    }
                }
            }
            finally
            {
                // 还原：编码页回原样；VT 状态回原样（不污染用户已有的 cmd 窗口习惯）
                if (origCodePage > 0)
                {
                    try { Console.OutputEncoding = Encoding.GetEncoding(origCodePage); } catch { }
                }
                if (modeOk)
                {
                    try { SetConsoleMode(hCon, oldMode); } catch { }
                }
                UnlockConsoleStyle();   // 归还窗口样式
            }

            // 双击场景（没带参数）停一下，否则窗口闪退看不到结果
            if (args.Length == 0)
            {
                Console.WriteLine();
                Console.WriteLine("  安装器已退出（exit code = " + code + "）。按回车关闭窗口...");
                try { Console.ReadLine(); }
                catch { }
            }
            return code;
        }

        private static byte[] ReadEmbedded()
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream(ResourceName))
            {
                if (s == null)
                    throw new InvalidOperationException("内嵌资源缺失: " + ResourceName);
                using (MemoryStream ms = new MemoryStream())
                {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = s.Read(buf, 0, buf.Length)) > 0)
                        ms.Write(buf, 0, n);
                    return ms.ToArray();
                }
            }
        }

        private static string Sha256Hex(byte[] data)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] h = sha.ComputeHash(data);
                StringBuilder sb = new StringBuilder(h.Length * 2);
                for (int i = 0; i < h.Length; i++)
                    sb.Append(h[i].ToString("x2"));
                return sb.ToString();
            }
        }

        private static string Quote(string a)
        {
            if (a != null && a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
                return a;
            return "\"" + (a == null ? string.Empty : a.Replace("\"", "\\\"")) + "\"";
        }
    }
}
