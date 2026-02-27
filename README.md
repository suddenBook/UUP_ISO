# UUP ISO Builder

A GitHub Actions workflow that builds Windows ISOs from UUP (Unified Update Platform) files. It downloads UUP files via the [UUP dump](https://uupdump.net/) API, converts them to a bootable ISO with integrated updates, and uploads split archives to GitHub Releases.

## Supported Products

- **Windows 11** — Latest builds from Retail, ReleasePreview, Beta, Dev, or Canary channels
- **Windows 10** — Latest 22H2 Feature Update (with ESU patches)
- **Windows Server** — Windows Server 2025 (24H2)

## Features

- Fetches the latest builds from UUP dump (always uses Feature Updates, never Cumulative Updates)
- Integrates cumulative updates into the image
- Includes all pre-installed Microsoft Store apps (Windows Terminal, Calculator, Photos, etc.)
- Runs DISM component cleanup and ResetBase for smaller images
- Integrates .NET Framework 3.5
- Optional driver integration via URL at build time
- Splits the final ISO into 1.9 GB 7z parts for GitHub Releases
- Fully automated — no manual interaction required

## Usage

1. **Fork** this repository
2. Go to the **Actions** tab and enable workflows
3. Click **"Build Windows ISO"** → **"Run workflow"**
4. Select your parameters:

| Parameter | Options | Default | Notes |
|-----------|---------|---------|-------|
| Product | Windows 11, Windows 10, Windows Server | Windows 11 | |
| Channel | Retail, ReleasePreview, Beta, Dev, Canary | Retail | Windows 11 only |
| Milestone | 25H2, 24H2 | 25H2 | Windows 11 Retail/RP only |
| Architecture | amd64, arm64 | amd64 | |
| Language | Free text | en-us | e.g., `zh-cn`, `de-de` |
| Edition | PROFESSIONAL, CORE, SERVERSTANDARD, etc. | PROFESSIONAL | Client editions for Win10/11; Server editions for Server |
| Drivers URL | URL to a zip file | *(empty)* | Optional, see [Driver Integration](#driver-integration) |

5. Wait for the workflow to complete (~1-3 hours)
6. Download the split 7z files from the **Releases** page

## Extracting the ISO

Download all `.7z.xxx` files to the same folder, then extract:

```
7z x <filename>.7z.001
```

This produces the full bootable ISO file.

## Driver Integration

You can integrate hardware drivers into the ISO by providing a URL to a zip file when triggering the workflow. The zip is downloaded at build time and is **not** stored in the repository, so forked repos stay clean.

### Preparing a Driver Package

1. Download the template zip from [`drivers-template.zip`](drivers-template.zip) included in this repository
2. Place your driver files into the appropriate subfolder:

| Folder | Injected into | Use case |
|--------|--------------|----------|
| `OS/` | `install.wim` only | Most hardware drivers (GPU, audio, chipset, etc.) |
| `WinPE/` | `boot.wim` / `winre.wim` only | Drivers needed during installation (storage controllers, NIC) |
| `ALL/` | All images | Drivers needed everywhere |

3. Each driver must be a complete INF driver package (`.inf` + `.sys` + `.cat` and any other referenced files). Only signed drivers are accepted.
4. Subdirectory nesting is fine — DISM scans recursively.

Example structure inside the zip:

```
OS/
  gpu-driver/
    nvidia.inf
    nvidia.sys
    nvidia.cat
WinPE/
  nvme-controller/
    stornvme.inf
    stornvme.sys
    stornvme.cat
```

### Exporting Drivers from an Existing System

[DriverStoreExplorer (RAPR)](https://github.com/lostindark/DriverStoreExplorer) is a handy open-source tool for browsing and exporting drivers from the Windows Driver Store. You can use it to select and export specific drivers, then organize the exported folders into the `OS/` or `WinPE/` structure described above.

### Using the Driver Package

1. Upload your zip file to any publicly accessible URL
2. When triggering the workflow, paste the URL into the **Drivers URL** field
3. The workflow will download, extract, and integrate the drivers automatically

[temp.sh](https://temp.sh) is a convenient no-signup temporary file hosting service (4 GB limit, files expire after 3 days). Upload with one command:

```bash
curl -F "file=@drivers.zip" https://temp.sh/upload
```

The returned URL can be pasted directly into the Drivers URL field. GitHub Release assets, cloud storage direct links, and other file hosting services also work.

If the field is left empty, no drivers are integrated — same as the default behavior.

## How It Works

1. **Query** — Calls the UUP dump API to find the latest matching build and get download URLs
2. **Download** — Uses aria2c with multi-connection downloads to fetch UUP files
3. **Convert** — Uses [abbodi1406's uup-converter-wimlib](https://github.com/abbodi1406/BatUtil) to:
   - Extract ESD files to WIM format
   - Mount images and apply updates with DISM
   - Run component cleanup with `/ResetBase`
   - Enable .NET Framework 3.5
   - Create bootable ISO with cdimage
4. **Split & Upload** — Splits the ISO into 1.9 GB 7z volumes and uploads to GitHub Releases

## Runner

Uses `windows-2022` runners which provide ~240 GB total disk space across C: and D: drives. The build process uses the D: drive for all working files.

## Credits

- [UUP dump](https://uupdump.net/) — API for finding and downloading UUP files
- [abbodi1406/BatUtil](https://github.com/abbodi1406/BatUtil) — UUP to ISO converter

## License

See [LICENSE](LICENSE).
