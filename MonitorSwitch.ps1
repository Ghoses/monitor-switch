# MonitorSwitch - System-Tray-App zum Stromsparen an physischen Monitoren.
# Strategie:
#   1) Helligkeit per Windows-API auf 0
#   2) Standby, solange "AUS" alle 2 s erneut erzwingen
#   3) Lokale Hardware (Hooks) beendet Stromspar; injizierte Remote-Eingaben nicht
# Aufloesung / Display-Layout bleiben unveraendert (kein Abklemmen).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\MonitorSwitchTrayApp", [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "Monitor Switch laeuft bereits (Infobereich).",
        "Monitor Switch",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DisplayPower {
    private const int HWND_BROADCAST = 0xFFFF;
    private const int WM_SYSCOMMAND = 0x0112;
    private const int SC_MONITORPOWER = 0xF170;
    private const int MOUSEEVENTF_MOVE = 0x0001;

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lpRect, MonitorEnumProc callback, IntPtr data);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern void mouse_event(int dwFlags, int dx, int dy, int dwData, IntPtr dwExtraInfo);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool DestroyPhysicalMonitors(uint count, PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetMonitorBrightness(IntPtr hMonitor, ref uint min, ref uint current, ref uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetMonitorBrightness(IntPtr hMonitor, uint brightness);

    public class BrightnessSnapshot {
        public string Description;
        public uint Value;
        public bool Ok;
    }

    private static PHYSICAL_MONITOR[] GetAllPhysicalMonitors() {
        var all = new List<PHYSICAL_MONITOR>();
        MonitorEnumProc callback = (IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data) => {
            uint count = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, ref count) || count == 0)
                return true;
            var arr = new PHYSICAL_MONITOR[count];
            if (GetPhysicalMonitorsFromHMONITOR(hMonitor, count, arr))
                all.AddRange(arr);
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        return all.ToArray();
    }

    public static BrightnessSnapshot[] SaveBrightness() {
        var monitors = GetAllPhysicalMonitors();
        var result = new BrightnessSnapshot[monitors.Length];
        for (int i = 0; i < monitors.Length; i++) {
            uint min = 0, cur = 0, max = 0;
            bool ok = GetMonitorBrightness(monitors[i].hPhysicalMonitor, ref min, ref cur, ref max);
            result[i] = new BrightnessSnapshot {
                Description = monitors[i].szPhysicalMonitorDescription,
                Value = cur,
                Ok = ok
            };
        }
        if (monitors.Length > 0)
            DestroyPhysicalMonitors((uint)monitors.Length, monitors);
        return result;
    }

    public static int SetAllBrightness(uint value) {
        var monitors = GetAllPhysicalMonitors();
        int changed = 0;
        for (int i = 0; i < monitors.Length; i++) {
            if (SetMonitorBrightness(monitors[i].hPhysicalMonitor, value))
                changed++;
        }
        if (monitors.Length > 0)
            DestroyPhysicalMonitors((uint)monitors.Length, monitors);
        return changed;
    }

    public static int RestoreBrightness(BrightnessSnapshot[] snapshots) {
        if (snapshots == null) return 0;
        var monitors = GetAllPhysicalMonitors();
        int restored = 0;
        int n = Math.Min(monitors.Length, snapshots.Length);
        for (int i = 0; i < n; i++) {
            if (snapshots[i] != null && snapshots[i].Ok) {
                if (SetMonitorBrightness(monitors[i].hPhysicalMonitor, snapshots[i].Value))
                    restored++;
            }
        }
        if (monitors.Length > 0)
            DestroyPhysicalMonitors((uint)monitors.Length, monitors);
        return restored;
    }

    public static void SleepDisplays() {
        SendMessage((IntPtr)HWND_BROADCAST, WM_SYSCOMMAND, (IntPtr)SC_MONITORPOWER, (IntPtr)2);
    }

    public static void WakeDisplays() {
        mouse_event(MOUSEEVENTF_MOVE, 1, 0, 0, IntPtr.Zero);
        mouse_event(MOUSEEVENTF_MOVE, -1, 0, 0, IntPtr.Zero);
    }
}

public static class LocalInputGuard {
    public const int WH_KEYBOARD_LL = 13;
    public const int WH_MOUSE_LL = 14;

    // Keyboard flags
    public const int LLKHF_INJECTED = 0x10;
    public const int LLKHF_LOWER_IL_INJECTED = 0x02;

    // Mouse flags
    public const int LLMHF_INJECTED = 0x01;
    public const int LLMHF_LOWER_IL_INJECTED = 0x02;

    public delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);
    public static event Action LocalHardwareInput;

    // Nur wecken, wenn Stromspar aktiv
    public static volatile bool Armed;

    private static IntPtr _kbHook = IntPtr.Zero;
    private static IntPtr _mouseHook = IntPtr.Zero;
    // Referenzen halten, sonst garbage-collectet der Callback
    private static LowLevelProc _kbProc;
    private static LowLevelProc _mouseProc;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT {
        public int x;
        public int y;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    private static void RaiseLocal() {
        var handler = LocalHardwareInput;
        if (handler != null) handler();
    }

    private static IntPtr KeyboardHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && Armed) {
            var info = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            uint injected = (uint)(LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED);
            if ((info.flags & injected) == 0)
                RaiseLocal();
        }
        return CallNextHookEx(_kbHook, nCode, wParam, lParam);
    }

    private static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && Armed) {
            var info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
            uint injected = (uint)(LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED);
            if ((info.flags & injected) == 0)
                RaiseLocal();
        }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    public static void Install() {
        if (_kbHook != IntPtr.Zero) return;
        _kbProc = KeyboardHook;
        _mouseProc = MouseHook;
        // LL-Hooks: hMod darf seit Vista NULL sein, wenn Callback im eigenen Prozess liegt
        _kbHook = SetWindowsHookEx(WH_KEYBOARD_LL, _kbProc, IntPtr.Zero, 0);
        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, IntPtr.Zero, 0);
        if (_kbHook == IntPtr.Zero || _mouseHook == IntPtr.Zero) {
            Uninstall();
            throw new InvalidOperationException("Low-Level-Hooks konnten nicht installiert werden.");
        }
    }

    public static void Uninstall() {
        Armed = false;
        if (_kbHook != IntPtr.Zero) {
            UnhookWindowsHookEx(_kbHook);
            _kbHook = IntPtr.Zero;
        }
        if (_mouseHook != IntPtr.Zero) {
            UnhookWindowsHookEx(_mouseHook);
            _mouseHook = IntPtr.Zero;
        }
        _kbProc = null;
        _mouseProc = null;
    }
}

public static class IconNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

$script:powerSaveOn = $false
$script:brightnessBackup = $null
$script:keepOffTimer = $null
$script:exiting = $false
$script:iconOn = $null
$script:iconOff = $null
$script:localWakePending = $false

function ConvertTo-OwnedIcon {
    param([System.Drawing.Bitmap]$Bitmap)
    $hIcon = $Bitmap.GetHicon()
    $temp = [System.Drawing.Icon]::FromHandle($hIcon)
    # Kopie mit eigenem Handle - sonst verschwindet das Tray-Icon
    $owned = [System.Drawing.Icon]::new($temp, $temp.Width, $temp.Height)
    [void][IconNative]::DestroyIcon($hIcon)
    return $owned
}

function New-StatusIcon {
    param([bool]$PowerSaveOn)

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    if ($PowerSaveOn) {
        # AUS: dunkler Monitor + rotes X
        $frame = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(55, 55, 60))
        $screen = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(20, 20, 24))
        $stand = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(90, 90, 95))
        $g.FillRectangle($frame, 4, 6, 24, 16)
        $g.FillRectangle($screen, 7, 9, 18, 10)
        $g.FillRectangle($stand, 13, 22, 6, 3)
        $g.FillRectangle($stand, 10, 25, 12, 2)
        $penX = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 70, 60), 2.5)
        $g.DrawLine($penX, 10, 11, 20, 17)
        $g.DrawLine($penX, 20, 11, 10, 17)
        $penX.Dispose()
        $frame.Dispose(); $screen.Dispose(); $stand.Dispose()
    }
    else {
        # AN: gruener Monitor mit leuchtendem Screen
        $frame = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 120, 70))
        $screen = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(180, 255, 200))
        $stand = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(50, 140, 80))
        $g.FillRectangle($frame, 4, 6, 24, 16)
        $g.FillRectangle($screen, 7, 9, 18, 10)
        $g.FillRectangle($stand, 13, 22, 6, 3)
        $g.FillRectangle($stand, 10, 25, 12, 2)
        $dot = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255))
        $g.FillEllipse($dot, 14, 12, 4, 4)
        $dot.Dispose()
        $frame.Dispose(); $screen.Dispose(); $stand.Dispose()
    }

    $icon = ConvertTo-OwnedIcon -Bitmap $bmp
    $g.Dispose()
    $bmp.Dispose()
    return $icon
}

function Initialize-TrayIcons {
    if ($null -ne $script:iconOn) { $script:iconOn.Dispose() }
    if ($null -ne $script:iconOff) { $script:iconOff.Dispose() }
    $script:iconOn = New-StatusIcon -PowerSaveOn:$false
    $script:iconOff = New-StatusIcon -PowerSaveOn:$true
}

function Stop-KeepOffTimer {
    if ($null -ne $script:keepOffTimer) {
        $script:keepOffTimer.Stop()
        $script:keepOffTimer.Dispose()
        $script:keepOffTimer = $null
    }
}

function Start-KeepOffTimer {
    Stop-KeepOffTimer
    $script:keepOffTimer = New-Object System.Windows.Forms.Timer
    $script:keepOffTimer.Interval = 2000
    $script:keepOffTimer.Add_Tick({
        if ($script:powerSaveOn) {
            [DisplayPower]::SleepDisplays()
            [void][DisplayPower]::SetAllBrightness(0)
        }
    })
    $script:keepOffTimer.Start()
}

function Update-TrayUi {
    if ($script:powerSaveOn) {
        $notify.Text = "Monitor Switch: AUS (Stromspar)"
        $menuToggle.Text = "Monitore einschalten"
        $menuStatus.Text = "Status: AUS"
        $notify.Icon = $script:iconOff
    }
    else {
        $notify.Text = "Monitor Switch: AN"
        $menuToggle.Text = "Monitore ausschalten (Stromspar)"
        $menuStatus.Text = "Status: AN"
        $notify.Icon = $script:iconOn
    }
}

function Enable-PowerSave {
    $script:brightnessBackup = [DisplayPower]::SaveBrightness()
    [void][DisplayPower]::SetAllBrightness(0)
    Start-Sleep -Milliseconds 800
    [DisplayPower]::SleepDisplays()
    Start-KeepOffTimer
    $script:powerSaveOn = $true
    [LocalInputGuard]::Armed = $true
    Update-TrayUi
    $notify.ShowBalloonTip(
        2000,
        "Monitor Switch",
        "Monitore aus. Lokal: Tastatur/Maus weckt. Remote: bleibt aus.",
        [System.Windows.Forms.ToolTipIcon]::Info
    )
}

function Disable-PowerSave {
    [LocalInputGuard]::Armed = $false
    Stop-KeepOffTimer
    $script:powerSaveOn = $false
    [DisplayPower]::WakeDisplays()
    Start-Sleep -Milliseconds 400
    if ($null -ne $script:brightnessBackup) {
        [void][DisplayPower]::RestoreBrightness($script:brightnessBackup)
    }
    else {
        [void][DisplayPower]::SetAllBrightness(80)
    }
    $script:brightnessBackup = $null
    Update-TrayUi
    if (-not $script:exiting) {
        $notify.ShowBalloonTip(
            2000,
            "Monitor Switch",
            "Monitore wieder an.",
            [System.Windows.Forms.ToolTipIcon]::Info
        )
    }
}

function Switch-PowerSave {
    try {
        if ($script:powerSaveOn) {
            Disable-PowerSave
        }
        else {
            Enable-PowerSave
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Fehler: $($_.Exception.Message)",
            "Monitor Switch",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Request-LocalWake {
    if (-not $script:powerSaveOn) { return }
    if ($script:localWakePending) { return }
    if ($script:exiting) { return }
    $script:localWakePending = $true
    try {
        [void]$form.BeginInvoke([Action]{
            try {
                if ($script:powerSaveOn -and -not $script:exiting) {
                    Disable-PowerSave
                }
            }
            finally {
                $script:localWakePending = $false
            }
        })
    }
    catch {
        $script:localWakePending = $false
    }
}

# Verstecktes Fenster als Message-Loop-Host (noetig fuer Hooks + Tray)
$form = New-Object System.Windows.Forms.Form
$form.WindowState = "Minimized"
$form.ShowInTaskbar = $false
$form.Opacity = 0
$form.FormBorderStyle = "FixedToolWindow"
$form.Size = New-Object System.Drawing.Size(0, 0)

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$menuStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$menuStatus.Enabled = $false
$menuStatus.Text = "Status: AN"
[void]$menu.Items.Add($menuStatus)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$menuToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$menuToggle.Text = "Monitore ausschalten (Stromspar)"
$menuToggle.Add_Click({ Switch-PowerSave })
[void]$menu.Items.Add($menuToggle)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExit.Text = "Beenden"
$menuExit.Add_Click({
    $script:exiting = $true
    $form.Close()
})
[void]$menu.Items.Add($menuExit)

Initialize-TrayIcons

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$notify.ContextMenuStrip = $menu
$notify.Icon = $script:iconOn
$notify.Text = "Monitor Switch: AN"

$notify.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Switch-PowerSave
    }
})

$form.Add_FormClosing({
    $script:exiting = $true
    [LocalInputGuard]::Armed = $false
    try { [LocalInputGuard]::Uninstall() } catch { }

    if ($script:powerSaveOn) {
        Disable-PowerSave
    }
    else {
        Stop-KeepOffTimer
    }

    $notify.Visible = $false
    $notify.Icon = $null
    $notify.Dispose()
    $menu.Dispose()

    if ($null -ne $script:iconOn) { $script:iconOn.Dispose(); $script:iconOn = $null }
    if ($null -ne $script:iconOff) { $script:iconOff.Dispose(); $script:iconOff = $null }

    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
})

$script:localWakeHandler = [Action]{ Request-LocalWake }

$form.Add_Shown({
    $form.Hide()
    try {
        [LocalInputGuard]::Install()
        [LocalInputGuard]::add_LocalHardwareInput($script:localWakeHandler)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Hooks fehlgeschlagen: $($_.Exception.Message)`nUmschalten per Tray funktioniert weiter.",
            "Monitor Switch",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    $notify.ShowBalloonTip(
        2500,
        "Monitor Switch",
        "Infobereich: gruen=AN, grau+X=AUS.`nLinksklick: umschalten.`nLokal Tastatur/Maus weckt.",
        [System.Windows.Forms.ToolTipIcon]::Info
    )
})

Update-TrayUi
[System.Windows.Forms.Application]::Run($form)
