# Codex Windows Setup

One-command Windows bootstrap for OpenAI Codex tooling.

Run in Windows PowerShell, PowerShell 7, Windows Terminal, or VS Code Terminal:

```powershell
irm https://github.com/OlegGorsky/w/raw/main/i.ps1|iex
```

It installs or repairs:

- PowerShell 7
- Node.js LTS
- Microsoft Visual C++ Redistributable
- Codex CLI for Windows
- Microsoft Store/App Installer/winget where supported
- Codex Desktop from Microsoft Store
- WSL/Ubuntu
- Codex CLI inside WSL after the distro is initialized

Full script: [`Setup-CodexWindows.ps1`](./Setup-CodexWindows.ps1)

Dry run after cloning:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-CodexWindows.ps1 -CheckOnly
```

Local static check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Setup-CodexWindows.ps1
```
