# Codex Windows Setup

One-command Windows bootstrap for OpenAI Codex tooling.

Run in Windows PowerShell, PowerShell 7, Windows Terminal, or VS Code Terminal:

```powershell
irm https://oleggorsky.github.io/w/i.ps1|iex
```

Fallback if GitHub Pages is unavailable:

```powershell
irm https://github.com/OlegGorsky/w/raw/main/i.ps1|iex
```

It installs or repairs:

- PowerShell 7
- Node.js LTS
- Microsoft Visual C++ Redistributable
- Codex CLI for Windows
- Microsoft Store/App Installer/winget where supported
- Codex Desktop from official Microsoft Store paths
- WSL/Ubuntu
- Codex CLI inside WSL after the distro is initialized

Codex Desktop is installed only through official Microsoft Store infrastructure:
`winget -s msstore` where available, then Microsoft's official Store web
installer for the Codex product ID (`9PLM9XGG6VKS`). The script does not use
third-party MSIX mirrors.

On Windows Server 2022 and older, Microsoft Store/App Installer support is not
the normal desktop-client path. The script will still try the official Microsoft
Store web installer and will fail clearly if Microsoft blocks the install. For a
fully supported Desktop setup, use Windows 10/11 client or another Windows build
where Microsoft App Installer/Store installs are supported.

Full script: [`Setup-CodexWindows.ps1`](./Setup-CodexWindows.ps1)

Dry run after cloning:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-CodexWindows.ps1 -CheckOnly
```

Local static check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Setup-CodexWindows.ps1
```
