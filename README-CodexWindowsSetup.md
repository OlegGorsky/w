# Codex Windows Setup

Universal Windows bootstrap for setting up OpenAI Codex tooling.

It is designed to be launched from Windows PowerShell, PowerShell 7, VS Code
Terminal, Windows Terminal, or `cmd.exe`. If needed, it relaunches itself through
a stable elevated Windows PowerShell host, repairs Microsoft Store/App Installer
registration, restores `winget`, installs or updates PowerShell 7, Node.js LTS,
Microsoft Visual C++ Redistributable, Codex CLI for Windows, WSL/Ubuntu, Codex
CLI inside WSL, and Codex Desktop from official Microsoft Store paths.

## Quick Start

Open any Windows terminal and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-CodexWindows.ps1
```

Or from `cmd.exe`:

```cmd
Run-Setup-CodexWindows.cmd
```

Dry run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-CodexWindows.ps1 -CheckOnly
```

## Useful Options

```powershell
# Update all winget-managed packages too
.\Setup-CodexWindows.ps1 -UpdateAllWingetPackages

# Trigger Windows Update scan/download/install commands
.\Setup-CodexWindows.ps1 -RunWindowsUpdate

# Skip WSL-side Codex CLI installation
.\Setup-CodexWindows.ps1 -SkipCodexCliInWsl

# Skip Microsoft Visual C++ Redistributable installation
.\Setup-CodexWindows.ps1 -SkipVcRedist

# Skip desktop app installation
.\Setup-CodexWindows.ps1 -SkipCodexDesktop

# Diagnose Store policies only by default; explicitly repair them
.\Setup-CodexWindows.ps1 -RepairStorePolicies

# Skip OS/build support gate
.\Setup-CodexWindows.ps1 -SkipWindowsSupportCheck

# Install extra developer tools: Git, Python, GitHub CLI
.\Setup-CodexWindows.ps1 -InstallRecommendedDevTools
```

## Notes

- Run the script on the target Windows machine.
- Administrator rights are required for WSL, App Installer repair, MSI installs,
  and Store registration repair. The script requests elevation automatically.
- Windows support is checked up front. Current scripted setup expects Windows 10
  1809/build 17763 or newer; WSL distro setup expects Windows 10 2004/build
  19041 or newer.
- Windows Server is supported for CLI-oriented setup, but Microsoft Store apps
  are not part of the normal Server 2022 client-app path. Codex Desktop is
  attempted only through official Microsoft Store infrastructure: `winget -s
  msstore` where available, then Microsoft's official Store web installer for
  product ID `9PLM9XGG6VKS`. The script does not use third-party MSIX mirrors.
  If Microsoft blocks the install on Windows Server, the Desktop step fails
  clearly instead of reporting a false success.
- Store policy registry values are reported by default. They are changed only
  when `-RepairStorePolicies` is passed.
- WSL distro initialization can still require one interactive first launch to
  create the Linux user. After that, rerun the script and it will install Codex
  CLI inside WSL.
- Logs are written to `%TEMP%\codex-windows-setup-*.log`.

## Local Static Check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Setup-CodexWindows.ps1
```
