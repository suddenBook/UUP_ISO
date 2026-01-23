# UUP ISO Builder

A GitHub Actions workflow that builds Windows 11 ISOs from UUP (Unified Update Platform) files. It downloads UUP files via the [UUP dump](https://uupdump.net/) API, converts them to a bootable ISO with integrated updates, and uploads split archives to GitHub Releases.

## Features

- Fetches the latest Windows 11 builds from any update channel
- Integrates cumulative updates into the image
- Runs DISM component cleanup and ResetBase for smaller images
- Integrates .NET Framework 3.5
- Splits the final ISO into 1.9 GB 7z parts for GitHub Releases
- Fully automated — no manual interaction required

## Usage

1. **Fork** this repository
2. Go to the **Actions** tab and enable workflows
3. Click **"Build Windows ISO"** → **"Run workflow"**
4. Select your parameters:

| Parameter | Options | Default | Description |
|-----------|---------|---------|-------------|
| Channel | Retail, ReleasePreview, Beta, Dev, Canary | Retail | Update channel |
| Milestone | 25H2, 24H2 | 25H2 | Windows version (Retail/RP only) |
| Architecture | amd64, arm64 | amd64 | CPU architecture |
| Language | Free text | en-us | Language code (e.g., `zh-cn`, `de-de`) |
| Edition | PROFESSIONAL, CORE | PROFESSIONAL | Pro or Home |

5. Wait for the workflow to complete (~1-3 hours)
6. Download the split 7z files from the **Releases** page

## Extracting the ISO

Download all `.7z.xxx` files to the same folder, then extract:

```
7z x <filename>.7z.001
```

This produces the full bootable ISO file.

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
