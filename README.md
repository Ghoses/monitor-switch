# Monitor Switch

Lightweight Windows system-tray app that turns physical monitors dark while you work remotely (AnyDesk, VNC, …) — without changing the Windows display layout or remote resolution.

## Features

- **Tray icon** shows state clearly:
  - **On** — green monitor
  - **Off** — dark monitor with red X
- **Power save**: brightness → 0 (DDC/CI) + display standby (re-applied while off)
- **Remote stays usable**: desktop framebuffer unchanged, so remote viewers keep working
- **Local wake**: real keyboard/mouse input turns monitors back on
- **Remote input ignored**: injected input (typical for remote tools) does not wake the screens
- Single instance; restoring monitors on exit

## Requirements

- Windows 10 / 11
- Monitors that support DDC/CI brightness (most modern displays)

## Usage

1. Double-click `MonitorSwitch.bat`
2. Find the icon in the system tray (notification area)
3. **Left-click** — toggle on/off  
   **Right-click** — menu (status / toggle / exit)

Optional: create a shortcut in the Startup folder if you want it at login.

## How it works

| Mode | What happens |
|------|----------------|
| **Off** | Brightness set to 0, standby forced; remote session keeps full resolution |
| **On** | Previous brightness restored |
| Local input while off | Ends power-save (non-injected HID only) |

Displays are **not** disconnected in Windows Settings — that would often change remote resolution.

## Files

| File | Purpose |
|------|---------|
| `MonitorSwitch.ps1` | Tray application |
| `MonitorSwitch.bat` | Launcher (hidden PowerShell window) |

## License

MIT — see [LICENSE](LICENSE).
