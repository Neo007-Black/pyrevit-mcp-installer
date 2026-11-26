# Build the EXE from source

Large third-party files are not stored in the repository. You collect them once.

## You need

| Item | Where |
|---|---|
| `pyRevit_7.1.0.26319_signed.exe` and `pyRevit_6.5.5.26237_signed.exe` | [pyRevit releases](https://github.com/pyrevitlabs/pyRevit/releases) |
| [uv](https://docs.astral.sh/uv/) | To manage Python |
| A uv-managed CPython 3.13 (64-bit) | `uv python install 3.13` |
| Internet, once | To fill the package cache |

The C# compiler used for the EXE ships with Windows.

## Steps

1. Put both pyRevit setup files in `%USERPROFILE%\Downloads\pyrevit_setup` (or pass `-InstallerSource`).

2. Download the pinned packages into the `wheels` folder:

```powershell
uv run --python 3.13 --with pip python -m pip download -r requirements.pinned.txt -d wheels --only-binary=:all:
```

This command has not been tested as part of this project's own build.

3. Build the offline payload:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-Payload.ps1
```

4. Build the EXE (close any open setup window first):

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1
```

The result is `dist\PyRevitMCP-Setup.exe` with its SHA-256 in a text file.

## Changing versions

- Python packages: edit `requirements.pinned.txt`.
- pyRevit: update the file names in `Build-Payload.ps1`, and the names, version and **SHA-256 values** at the top of `lib\Core.ps1`. The installer refuses a file whose hash differs.
- Icon and sound: `New-Icon.ps1`, `New-StartupSound.ps1`.

## Layout

| Path | Purpose |
|---|---|
| `Installer.ps1` | Window |
| `lib\Core.ps1` | Install and uninstall logic |
| `lib\Existing.ps1` | Removal of setups made another way |
| `extension\` | MCP extension (modified third-party code) |
| `exe\` | Source of the single-file launcher |
| `Install.bat`, `Uninstall.bat` | Run from a folder that has a built `payload` |
