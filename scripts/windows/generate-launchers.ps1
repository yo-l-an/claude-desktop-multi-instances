# Windows counterpart of generate-launchers.swift: one tinted Start Menu shortcut per config entry.
. (Join-Path $PSScriptRoot 'common.ps1')

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace ClaudeProfiles {
    public static class IconTinter {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SHDefExtractIconW(string path, int index, uint flags, out IntPtr large, out IntPtr small, uint sizes);
        [DllImport("user32.dll")]
        static extern bool DestroyIcon(IntPtr handle);

        public static Bitmap Extract(string path) {
            IntPtr large, small;
            if (SHDefExtractIconW(path, 0, 0, out large, out small, (16u << 16) | 256u) != 0 || large == IntPtr.Zero)
                throw new Exception("Cannot read Claude's icon from " + path);
            try { using (Icon icon = Icon.FromHandle(large)) return icon.ToBitmap(); }
            finally { DestroyIcon(large); if (small != IntPtr.Zero) DestroyIcon(small); }
        }

        static void ToHsv(double r, double g, double b, out double h, out double s, out double v) {
            double max = Math.Max(r, Math.Max(g, b)), d = max - Math.Min(r, Math.Min(g, b));
            v = max; s = max == 0 ? 0 : d / max;
            if (d == 0) h = 0;
            else if (max == r) h = ((g - b) / d + 6) % 6;
            else if (max == g) h = (b - r) / d + 2;
            else h = (r - g) / d + 4;
            h /= 6;
        }

        static void FromHsv(double h, double s, double v, out double r, out double g, out double b) {
            double i = Math.Floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
            switch ((int)i % 6) {
                case 0: r = v; g = t; b = p; break;
                case 1: r = q; g = v; b = p; break;
                case 2: r = p; g = v; b = t; break;
                case 3: r = p; g = q; b = v; break;
                case 4: r = t; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
        }

        // Same recipe as the macOS builder: recolor saturated pixels, preserve white details and alpha.
        static bool Tint(Bitmap bitmap, int rgb) {
            double th, ts, tv;
            ToHsv(((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0, out th, out ts, out tv);
            Rectangle area = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
            BitmapData data = bitmap.LockBits(area, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            byte[] pixels = new byte[data.Stride * data.Height];
            Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            bool visible = false;
            for (int y = 0; y < data.Height; y++) {
                for (int x = 0; x < data.Width; x++) {
                    int o = y * data.Stride + x * 4;
                    if (pixels[o + 3] == 0) continue;
                    if (pixels[o + 3] > 127) visible = true;
                    double h, s, v, r, g, b;
                    ToHsv(pixels[o + 2] / 255.0, pixels[o + 1] / 255.0, pixels[o] / 255.0, out h, out s, out v);
                    if (s <= 0.12) continue;
                    FromHsv(th, Math.Min(1, s * ts / 0.85), Math.Min(1, v * tv / 0.95), out r, out g, out b);
                    pixels[o + 2] = (byte)Math.Round(r * 255);
                    pixels[o + 1] = (byte)Math.Round(g * 255);
                    pixels[o] = (byte)Math.Round(b * 255);
                }
            }
            Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
            bitmap.UnlockBits(data);
            return visible;
        }

        static byte[] Png(Bitmap bitmap) {
            using (MemoryStream png = new MemoryStream()) { bitmap.Save(png, ImageFormat.Png); return png.ToArray(); }
        }

        static byte[] Dib(Bitmap bitmap) {
            int size = bitmap.Width, maskStride = ((size + 31) / 32) * 4;
            using (MemoryStream stream = new MemoryStream())
            using (BinaryWriter writer = new BinaryWriter(stream)) {
                // BITMAPINFOHEADER; the height counts the color rows and the AND mask rows.
                writer.Write(40); writer.Write(size); writer.Write(size * 2); writer.Write((short)1); writer.Write((short)32);
                writer.Write(0); writer.Write(size * size * 4 + maskStride * size); writer.Write(0); writer.Write(0); writer.Write(0); writer.Write(0);
                byte[] mask = new byte[maskStride * size];
                for (int y = size - 1; y >= 0; y--) {
                    for (int x = 0; x < size; x++) {
                        Color pixel = bitmap.GetPixel(x, y);
                        writer.Write(pixel.B); writer.Write(pixel.G); writer.Write(pixel.R); writer.Write(pixel.A);
                        if (pixel.A == 0) mask[(size - 1 - y) * maskStride + x / 8] |= (byte)(0x80 >> (x % 8));
                    }
                }
                writer.Write(mask);
                return stream.ToArray();
            }
        }

        public static void Write(Bitmap source, int rgb, string output) {
            int[] sizes = { 16, 20, 24, 32, 40, 48, 64, 96, 128, 256 };
            List<byte[]> images = new List<byte[]>();
            foreach (int size in sizes) {
                using (Bitmap bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb)) {
                    using (Graphics graphics = Graphics.FromImage(bitmap)) {
                        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        graphics.CompositingQuality = CompositingQuality.HighQuality;
                        graphics.DrawImage(source, new Rectangle(0, 0, size, size));
                    }
                    if (!Tint(bitmap, rgb)) throw new Exception("Windows could not render Claude's icon. Run from a logged-in desktop session.");
                    images.Add(size >= 256 ? Png(bitmap) : Dib(bitmap));
                }
            }
            // Windows reads PNG frames reliably only at 256 px; smaller frames use 32-bit bitmaps.
            using (BinaryWriter writer = new BinaryWriter(File.Create(output))) {
                writer.Write((short)0); writer.Write((short)1); writer.Write((short)sizes.Length);
                int offset = 6 + 16 * sizes.Length;
                for (int i = 0; i < sizes.Length; i++) {
                    byte edge = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
                    writer.Write(edge); writer.Write(edge); writer.Write((byte)0); writer.Write((byte)0);
                    writer.Write((short)1); writer.Write((short)32);
                    writer.Write(images[i].Length); writer.Write(offset);
                    offset += images[i].Length;
                }
                foreach (byte[] image in images) writer.Write(image);
            }
        }
    }
}
'@

function ConvertFrom-HexColor([string]$Value) {
    if ($Value -cnotmatch '^#[0-9A-Fa-f]{6}$') { throw "Invalid color '$Value'. Use a hex code in #RRGGBB format." }
    [Convert]::ToInt32($Value.Substring(1), 16)
}

function Read-Config([string]$Path) {
    $config = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if (-not $config -or -not $config.PSObject.Properties['apps']) { throw 'config.json needs an "apps" array.' }
    $apps = $config.apps
    # A fresh install starts with {"apps": {}}; populated configs use an array.
    if ($apps -is [Management.Automation.PSCustomObject] -and @($apps.PSObject.Properties).Count -eq 0) {
        return @{ Placeholder = $true; Apps = @() }
    }
    if ($apps -isnot [array]) { throw 'config.json apps must be an array.' }
    $entries = foreach ($app in $apps) {
        foreach ($field in 'profile', 'name', 'color') {
            if (-not ($app -is [Management.Automation.PSCustomObject] -and $app.PSObject.Properties[$field] -and $app.$field -is [string])) {
                throw 'Each app needs the string fields profile, name, and color.'
            }
        }
        [pscustomobject]@{ profile = $app.profile; name = $app.name; color = $app.color; filename = $app.name + '.lnk' }
    }
    @{ Placeholder = $false; Apps = @($entries) }
}

function Assert-ValidConfig($Apps) {
    $names = @{}; $profiles = @{}
    foreach ($app in $Apps) {
        if (-not (Test-ValidProfile $app.profile)) {
            throw "Profiles must use 1-64 lowercase letters, numbers, or hyphens: $($app.profile)"
        }
        $name = $app.name
        if (-not $name -or $name -ne $name.Trim() -or $name.StartsWith('.') -or $name.EndsWith('.') -or
            $name -match '\.lnk$' -or $app.filename.Length -gt 240 -or $name -match '[\x00-\x1f<>:"/\\|?*]' -or
            ($name -split '\.')[0].TrimEnd() -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') {
            throw "Invalid app name: $name"
        }
        $key = $name.Normalize().ToLowerInvariant()
        if ($names.ContainsKey($key) -or $profiles.ContainsKey($app.profile)) {
            throw 'Each app needs a unique name and profile (including default).'
        }
        $names[$key] = $true; $profiles[$app.profile] = $true
        [void](ConvertFrom-HexColor $app.color)
    }
}

function New-Launcher($App, $Claude, $BaseIcon, [string]$Staging) {
    $built = Join-Path $Staging "$($App.profile).ico"
    [ClaudeProfiles.IconTinter]::Write($BaseIcon, (ConvertFrom-HexColor $App.color), $built)
    $digest = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant()
    # A new filename invalidates Explorer's cached icon when changing color.
    $icon = Join-Path $IconStore "$($App.profile)-$digest.ico"
    if (-not (Test-Path -LiteralPath $icon)) { Copy-Item -LiteralPath $built -Destination $icon }
    $shortcut = $Shell.CreateShortcut((Join-Path $Staging $App.filename))
    $shortcut.TargetPath = $Claude.Launch
    $shortcut.Arguments = (Get-LaunchArguments $App.profile) -join ' '
    $shortcut.IconLocation = "$icon,0"
    $shortcut.Description = $LauncherMarker + $App.profile
    $shortcut.WorkingDirectory = $env:USERPROFILE
    $shortcut.Save()
    $icon
}

# Replace only this tool's shortcuts. Stage replacements first; restore originals on failure.
function Install-Launchers($Apps, [string]$Staging, [string]$Destination, [bool]$Prune) {
    Assert-NoReparsePoint $Destination
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $wanted = @($Apps | ForEach-Object { $_.profile })
    $previous = @(); $seen = @{}
    foreach ($item in Get-ChildItem -LiteralPath $Destination -Filter *.lnk -File -Force) {
        # Match by profile to also migrate renamed launchers.
        $launcherProfile = Get-LauncherProfile $item.FullName
        if (-not $launcherProfile -or -not ($Prune -or $wanted -contains $launcherProfile)) { continue }
        if ($seen.ContainsKey($launcherProfile)) { throw "Duplicate installed launcher profile: $launcherProfile" }
        $seen[$launcherProfile] = $true
        $previous += $item.FullName
    }
    foreach ($app in $Apps) {
        $target = Join-Path $Destination $app.filename
        if ((Test-Path -LiteralPath $target) -and -not @($previous | Where-Object { Test-SamePath $_ $target }).Count) {
            throw "Another file already uses this name: $target"
        }
    }
    $transaction = Join-Path $Destination ".claude-profiles-$([guid]::NewGuid())"
    $backup = Join-Path $transaction 'old'
    $prepared = Join-Path $transaction 'new'
    New-Item -ItemType Directory -Force -Path $backup, $prepared | Out-Null
    (Get-Item -LiteralPath $transaction -Force).Attributes += 'Hidden'
    $moved = @(); $installed = @()
    try {
        foreach ($app in $Apps) { Copy-Item -LiteralPath (Join-Path $Staging $app.filename) -Destination (Join-Path $prepared $app.filename) }
        foreach ($old in $previous) {
            Move-Item -LiteralPath $old -Destination (Join-Path $backup (Split-Path -Leaf $old))
            $moved += $old
        }
        foreach ($app in $Apps) {
            $target = Join-Path $Destination $app.filename
            Move-Item -LiteralPath (Join-Path $prepared $app.filename) -Destination $target
            $installed += $target
        }
    } catch {
        $originalError = $_
        try {
            foreach ($target in $installed) { Remove-Item -LiteralPath $target -Force }
            foreach ($old in $moved) { Move-Item -LiteralPath (Join-Path $backup (Split-Path -Leaf $old)) -Destination $old }
            Remove-Item -LiteralPath $transaction -Recurse -Force
        } catch {
            throw "Update failed. Previous launchers are backed up at $backup. $($_.Exception.Message)"
        }
        throw $originalError
    }
    Remove-Item -LiteralPath $transaction -Recurse -Force
}

function Resolve-UserPath([string]$Value) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value)
}

function Main([string[]]$Arguments) {
    $configPath = Join-Path $Root 'config.json'
    $output = Join-Path $Root 'apps'
    $destination = $DefaultInstallDir
    $install = $false; $validateOnly = $false
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($argument in $Arguments) { $queue.Enqueue($argument) }
    while ($queue.Count) {
        $option = $queue.Dequeue()
        switch -CaseSensitive ($option) {
            '--install' { $install = $true }
            '--validate' { $validateOnly = $true }
            { $_ -in '--config', '--output', '--install-dir' } {
                if (-not $queue.Count) { throw "Missing value for $option" }
                $path = Resolve-UserPath $queue.Dequeue()
                if ($option -eq '--config') { $configPath = $path }
                if ($option -eq '--output') { $output = $path }
                if ($option -eq '--install-dir') { $destination = $path; $install = $true }
            }
            { $_ -in '--help', '-h' } {
                Write-Host 'Usage: "Claude Profiles - Windows.cmd" create [--validate] [--config FILE] [--output DIR] [--install-dir DIR]'
                return
            }
            default { throw "Unknown argument: $option" }
        }
    }
    if (-not (Test-Path -LiteralPath $configPath)) {
        if (-not $install -or $validateOnly) { throw 'Missing config. Run Claude Profiles - Windows.cmd (Create launchers) or copy config.example.json to config.json.' }
        [IO.File]::WriteAllText($configPath, "{`n  `"apps`": {}`n}`n")
        Write-Warning "Config was missing. Created $configPath with an empty apps object. Add your apps using config.example.json, then run the installer again."
        return
    }
    $config = Read-Config $configPath
    Assert-ValidConfig $config.Apps
    if ($validateOnly) { Write-Host "Valid configuration: $($config.Apps.Count) apps."; return }
    if ($config.Placeholder) {
        Write-Warning 'No apps configured. Replace apps: {} with the array from config.example.json, then run the installer again.'
        return
    }
    $claude = Find-Claude
    if ($install -and (Test-SamePath $output $destination)) { throw 'Build output and installation directory must be different.' }
    $work = Join-Path $Root ".build\$([guid]::NewGuid())"
    $staging = Join-Path $work 'apps'
    New-Item -ItemType Directory -Force -Path $staging, $IconStore | Out-Null
    try {
        $base = [ClaudeProfiles.IconTinter]::Extract($claude.Executable)
        $icons = @()
        foreach ($app in $config.Apps) {
            $icons += New-Launcher $app $claude $base $staging
            Write-Host "Built: $($app.name)"
        }
        Install-Launchers $config.Apps $staging $output $true
        if ($install) { Install-Launchers $config.Apps $staging $destination $false }
    } finally {
        Remove-Item -LiteralPath (Join-Path $Root '.build') -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Drop icons left over from earlier colors of the configured profiles.
    foreach ($app in $config.Apps) {
        foreach ($stale in Get-ChildItem -LiteralPath $IconStore -Filter "$($app.profile)-*.ico" -File) {
            if ($stale.Name -cmatch "^$($app.profile)-[0-9a-f]{16}\.ico$" -and -not @($icons | Where-Object { Test-SamePath $_ $stale.FullName }).Count) {
                Remove-Item -LiteralPath $stale.FullName -Force
            }
        }
    }
    Write-Host "$($config.Apps.Count) launchers in $output"
    if ($install) { Write-Host "Installed in $destination" }
}

try { Main $args; exit 0 }
catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 1
}
