using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

namespace HermesInstallCnGui
{
    /// <summary>
    /// hermes-install-cn-gui.exe —— 图形版安装器。
    /// 内嵌与 CLI 同一份 install-cn.ps1；界面上的三个参数（代理/固化/仅命令行）
    /// 拼成命令传给 powershell -ExecutionPolicy Bypass，日志实时回显。
    /// --selftest：不弹窗，解包+指纹写 %TEMP%\hermes-gui-selftest.txt 后退出。
    /// </summary>
    internal static class Program
    {
        private const string ResourceName = "hermes_install_cn.installer.ps1";

        [STAThread]
        private static int Main(string[] args)
        {
            string script = Path.Combine(Path.GetTempPath(), "hermes-install-cn.ps1");

            if (args.Length == 1 && args[0].Equals("--selftest", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    byte[] data = ReadEmbedded();
                    File.WriteAllBytes(script, data);
                    string sha = Sha256Hex(data);
                    string report = "GUI selftest OK\r\nembedded=" + data.Length
                        + "\r\nsha256=" + sha + "\r\nextracted=" + script;
                    File.WriteAllText(
                        Path.Combine(Path.GetTempPath(), "hermes-gui-selftest.txt"),
                        report, Encoding.UTF8);
                    return 0;
                }
                catch (Exception ex)
                {
                    try
                    {
                        File.WriteAllText(
                            Path.Combine(Path.GetTempPath(), "hermes-gui-selftest.txt"),
                            "GUI selftest FAILED: " + ex.Message, Encoding.UTF8);
                    }
                    catch { }
                    return 1;
                }
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(script));
            return 0;
        }

        private static byte[] ReadEmbedded()
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream(ResourceName))
            {
                if (s == null)
                    throw new InvalidOperationException("embedded resource missing: " + ResourceName);
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

        internal static byte[] Embedded()
        {
            return ReadEmbedded();
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly string _scriptPath;
        private CheckBox _cbPersist;
        private CheckBox _cbNoDesktop;
        private TextBox _txtProxy;
        private TextBox _txtLog;
        private Button _btnRun;
        private Label _lblStatus;
        private Panel _anim;          // 底部细进度条容器
        private Timer _animTimer;     // 滑动动画
        private int _animX;           // 动画相位
        private bool _animRunning;
        private Process _proc;

        public MainForm(string scriptPath)
        {
            _scriptPath = scriptPath;
            BuildUi();
        }

        /// <summary>双缓冲面板：WinForms 默认逐帧直刷会闪，开启后一次成帧。</summary>
        private sealed class BufferedPanel : Panel
        {
            public BufferedPanel() { this.DoubleBuffered = true; }
        }

        private void BuildUi()
        {
            // ---- 基本窗口 ----
            this.Text = "Hermes Agent 国内加速安装";
            this.Font = new Font("Microsoft YaHei UI", 9F);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.AutoScaleMode = AutoScaleMode.Font;
            this.ClientSize = new Size(830, 640);
            this.MinimumSize = new Size(720, 560);
            this.BackColor = Color.White;

            // ---- 顶部说明（固定默认行为） ----
            Label info = new Label();
            info.AutoSize = false;
            info.Dock = DockStyle.Top;
            info.Height = 74;
            info.Padding = new Padding(10, 8, 10, 4);
            info.ForeColor = Color.FromArgb(60, 60, 60);
            info.Text =
                "固定默认行为（无需选择）：加速策略自动开启（GitHub 秒失败→切官方镜像，三道护栏自动降级）；" +
                "无人值守安装；默认安装桌面图形版。\r\n" +
                "参数区只保留确实需要你决定的三项。";
            this.Controls.Add(info);

            // ---- 参数区 ----
            FlowLayoutPanel opts = new FlowLayoutPanel();
            opts.Dock = DockStyle.Top;
            opts.Height = 98;
            opts.FlowDirection = FlowDirection.TopDown;
            opts.Padding = new Padding(10, 4, 10, 4);
            opts.WrapContents = false;

            _cbPersist = new CheckBox();
            _cbPersist.Text = "固化镜像变量到用户环境（-Persist，新窗口/以后 hermes update 生效）";
            _cbPersist.AutoSize = true;

            _cbNoDesktop = new CheckBox();
            _cbNoDesktop.Text = "只装命令行版，跳过桌面图形版（-NoDesktop）";
            _cbNoDesktop.AutoSize = true;

            FlowLayoutPanel proxyRow = new FlowLayoutPanel();
            proxyRow.AutoSize = true;
            proxyRow.FlowDirection = FlowDirection.LeftToRight;
            Label lblProxy = new Label();
            lblProxy.Text = "代理（留空不使用，例 66.66.66.1:10808）：";
            lblProxy.AutoSize = true;
            lblProxy.Padding = new Padding(0, 5, 0, 0);
            _txtProxy = new TextBox();
            _txtProxy.Width = 220;
            _txtProxy.TextChanged += delegate { ValidateState(); };
            proxyRow.Controls.Add(lblProxy);
            proxyRow.Controls.Add(_txtProxy);

            opts.Controls.Add(_cbPersist);
            opts.Controls.Add(_cbNoDesktop);
            opts.Controls.Add(proxyRow);
            this.Controls.Add(opts);

            // ---- 按钮行 ----
            FlowLayoutPanel btnRow = new FlowLayoutPanel();
            btnRow.Dock = DockStyle.Top;
            btnRow.Height = 50;
            btnRow.Padding = new Padding(10, 4, 10, 4);

            _btnRun = new Button();
            _btnRun.Text = "开始安装";
            _btnRun.Width = 130;
            _btnRun.Height = 32;
            _btnRun.BackColor = Color.FromArgb(0, 120, 215);
            _btnRun.ForeColor = Color.White;
            _btnRun.FlatStyle = FlatStyle.Flat;
            _btnRun.Click += delegate { StartInstall(); };

            Button btnOpen = new Button();
            btnOpen.Text = "打开安装目录";
            btnOpen.Width = 120;
            btnOpen.Height = 32;
            btnOpen.Click += delegate
            {
                try { Process.Start("explorer.exe", Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) + "\\hermes"); }
                catch { }
            };

            _lblStatus = new Label();
            _lblStatus.Text = "就绪";
            _lblStatus.AutoSize = true;
            _lblStatus.Padding = new Padding(12, 8, 0, 0);
            _lblStatus.ForeColor = Color.FromArgb(90, 90, 90);

            btnRow.Controls.Add(_btnRun);
            btnRow.Controls.Add(btnOpen);
            btnRow.Controls.Add(_lblStatus);
            this.Controls.Add(btnRow);

            // ---- 底部细进度条：自绘蓝色渐变滑条，贴窗口最下沿、与日志同色一体 ----
            _anim = new BufferedPanel();
            _anim.Dock = DockStyle.Bottom;
            _anim.Height = 12;
            _anim.BackColor = Color.FromArgb(24, 24, 24);
            _anim.Visible = false;
            _anim.Paint += delegate(object ps, PaintEventArgs pe)
            {
                if (!_animRunning) return;
                Graphics g = pe.Graphics;
                int w = _anim.ClientSize.Width;
                int h = _anim.ClientSize.Height;
                if (w < 60) return;
                // 暗色轨道：给光带一个"跑"的路
                using (SolidBrush track = new SolidBrush(Color.FromArgb(56, 56, 56)))
                    g.FillRectangle(track, 0, h / 2 - 1, w, 2);
                // 柔光扫带：两端 alpha=0 完全淡出，看不见"头尾"就没有跳变感
                int barW = 200;
                int span = w + barW;
                int x = _animX % span;
                DrawSweep(g, x - barW, w, h, barW);            // 主份
                DrawSweep(g, x - barW + span, w, h, barW);     // 越界副本 → 循环无缝
            };
            _animTimer = new Timer();
            _animTimer.Interval = 30;
            _animTimer.Tick += delegate { _animX += 8; _anim.Invalidate(); };
            this.Controls.Add(_anim);

            // ---- 日志 ----
            _txtLog = new TextBox();
            _txtLog.Multiline = true;
            _txtLog.ReadOnly = true;
            _txtLog.ScrollBars = ScrollBars.Vertical;
            _txtLog.WordWrap = false;
            _txtLog.Dock = DockStyle.Fill;
            _txtLog.BackColor = Color.FromArgb(24, 24, 24);
            _txtLog.ForeColor = Color.FromArgb(210, 210, 210);
            _txtLog.Font = new Font("Consolas", 9.5F);
            this.Controls.Add(_txtLog);

            // z-order：Controls.Add 顺序反着来，重排一次确保 Dock 生效
            this.Controls.SetChildIndex(_txtLog, 0);
            this.Controls.SetChildIndex(_anim, 1);
            this.Controls.SetChildIndex(btnRow, 2);
            this.Controls.SetChildIndex(opts, 3);
            this.Controls.SetChildIndex(info, 4);
        }

        private void DrawSweep(Graphics g, int sx, int w, int h, int barW)
        {
            if (sx + barW <= 0 || sx >= w) return;
            Rectangle r = new Rectangle(sx, 1, barW, h - 2);
            using (LinearGradientBrush b = new LinearGradientBrush(r, Color.White, Color.White, 0F))
            {
                ColorBlend cb = new ColorBlend(3);
                cb.Colors = new Color[] {
                    Color.FromArgb(0, 0, 120, 215),
                    Color.FromArgb(235, 135, 205, 255),
                    Color.FromArgb(0, 0, 120, 215) };
                cb.Positions = new float[] { 0F, 0.5F, 1F };
                b.InterpolationColors = cb;
                g.FillRectangle(b, r);
            }
        }

        private void ValidateState()
        {
            // 目前无需禁用条件；保留钩子便于扩展
        }

        private string BuildCommandArgs()
        {
            StringBuilder sb = new StringBuilder();
            if (_cbPersist.Checked) sb.Append(" -Persist");
            if (_cbNoDesktop.Checked) sb.Append(" -NoDesktop");
            string proxy = _txtProxy.Text.Trim();
            if (proxy.Length > 0)
            {
                if (proxy.IndexOf('\'') >= 0)
                    throw new ArgumentException("代理值不能包含单引号");
                sb.Append(" -Proxy '").Append(proxy).Append("'");
            }
            return sb.ToString();
        }

        private void StartInstall()
        {
            if (_proc != null && !_proc.HasExited)
                return;

            string extra;
            try { extra = BuildCommandArgs(); }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "参数错误", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // 解出内嵌脚本（ASCII 路径，避开中文/引号问题）
            try { File.WriteAllBytes(_scriptPath, Program.Embedded()); }
            catch (Exception ex)
            {
                MessageBox.Show(this, "无法写出安装脚本：" + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // -Command 形式：先把子进程输出统一成 UTF-8 再执行脚本，GUI 按 UTF-8 解码，全程无乱码
            string inner = "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false; & '"
                + _scriptPath + "'" + extra + "; exit $LASTEXITCODE";

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command \"" + inner.Replace("\"", "\\\"") + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = new UTF8Encoding(false);
            psi.StandardErrorEncoding = new UTF8Encoding(false);
            psi.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

            _txtLog.Clear();
            _btnRun.Enabled = false;
            _animX = 0;
            _animRunning = true;
            _anim.Visible = true;
            _animTimer.Start();
            _anim.Invalidate();
            _lblStatus.Text = "安装中…（首次 20-40 分钟；中断后重跑为缓存增量）";
            _lblStatus.ForeColor = Color.FromArgb(0, 120, 215);

            Process p = new Process();
            p.StartInfo = psi;
            p.EnableRaisingEvents = true;
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendLog(e.Data);
            };
            p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendLog(e.Data, true);
            };
            p.Exited += delegate
            {
                int code = p.ExitCode;
                BeginInvoke(new MethodInvoker(delegate
                {
                    _animRunning = false;
                    _anim.Visible = false;
                    _animTimer.Stop();
                    _btnRun.Enabled = true;
                    _lblStatus.Text = (code == 0)
                        ? "完成（exit 0）——建议运行 hermes doctor 体检"
                        : "失败（exit " + code + "）——直接点“开始安装”重跑，已下完的走缓存";
                    _lblStatus.ForeColor = (code == 0) ? Color.Green : Color.Firebrick;
                    AppendLog("---- 进程退出 exit=" + code + " ----");
                    _proc = null;
                }));
            };

            try
            {
                p.Start();
                _proc = p;
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                _animRunning = false;
                _anim.Visible = false;
                _animTimer.Stop();
                _btnRun.Enabled = true;
                _lblStatus.Text = "启动失败：" + ex.Message;
                _lblStatus.ForeColor = Color.Firebrick;
            }
        }

        private void AppendLog(string line)
        {
            AppendLog(line, false);
        }

        private void AppendLog(string line, bool isError)
        {
            if (this.IsDisposed) return;
            if (this.InvokeRequired)
            {
                try { this.BeginInvoke(new MethodInvoker(delegate { AppendLog(line, isError); })); }
                catch { }
                return;
            }
            if (_txtLog.TextLength > 400000)
                _txtLog.Clear();
            // 标准错误流只改颜色不改内容：uv/npm 的进度惯例走 stderr，并不是错误
            _txtLog.ForeColor = isError ? Color.Goldenrod : Color.FromArgb(210, 210, 210);
            _txtLog.AppendText(line + Environment.NewLine);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (_proc != null && !_proc.HasExited)
            {
                DialogResult r = MessageBox.Show(this,
                    "安装进程还在运行，关闭窗口将中断安装。确定关闭？",
                    "确认", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (r != DialogResult.Yes) { e.Cancel = true; return; }
                try { _proc.Kill(); } catch { }
            }
            base.OnFormClosing(e);
        }
    }
}
