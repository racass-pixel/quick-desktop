# Quick desktop installer

Inno Setup script that packages a per-user Windows installer for Quick.

## Prerequisites

- Flutter SDK on `PATH` (channel: stable)
- [Inno Setup 6+](https://jrsoftware.org/isdl.php) — `iscc.exe` on `PATH`
  - Locally: `choco install innosetup -y`

## Build a release locally

From the repo root:

```powershell
$env:Path = "C:\src\flutter\bin;" + $env:Path

flutter build windows --release
iscc installer\quick-desktop.iss /DAppVersion=1.2.3
```

The installer lands at:

```
dist\quick-desktop-v1.2.3-windows-x64.exe
```

The asset name matches the regex the updater expects
(`*-windows-x64.exe`), so it can be uploaded to a GitHub release as-is.

## Publish a release

Tagging and pushing triggers `.github/workflows/release.yml`, which builds
and uploads the asset automatically:

```powershell
git tag v1.2.3
git push --tags
```

Manual upload (one-off) once the artifact exists:

```powershell
gh release create v1.2.3 dist\quick-desktop-v1.2.3-windows-x64.exe `
  --title "Quick v1.2.3" `
  --notes "See CHANGELOG.md"
```

## How the silent update works

`UpdaterService.launchAndQuit()` runs the downloaded installer with:

```
/SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS
```

Combined with `CloseApplications=yes` + `RestartApplications=yes` in the
`.iss`, Inno Setup gracefully closes the running `quick_desktop.exe`,
overwrites the install tree, and relaunches the app — no UAC prompt because
the install is per-user (`PrivilegesRequired=lowest`).
