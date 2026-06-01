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

Codex Desktop has no official standalone Windows `.exe` installer. The script
uses Store-based paths instead: `winget -s msstore` where available, Microsoft's
official Store web installer for product ID `9PLM9XGG6VKS`, and then a direct
Microsoft Store CDN MSIX fallback resolved from Microsoft Store metadata. The
MSIX fallback checks the Authenticode signature and does not use third-party
MSIX mirrors.

On Windows Server 2022 and older, Microsoft Store/App Installer support is not
the normal desktop-client path. The script skips the Store web installer loop on
those builds and tries the direct signed MSIX fallback instead. For a fully
supported Desktop setup, use Windows 10/11 client or another Windows build where
Microsoft App Installer/Store installs are supported.

Full script: [`Setup-CodexWindows.ps1`](./Setup-CodexWindows.ps1)

Dry run after cloning:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-CodexWindows.ps1 -CheckOnly
```

Local static check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Setup-CodexWindows.ps1
```
