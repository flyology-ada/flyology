# Installing Alire

Check whether `alr` is already available:
```bash
alr --version 2>/dev/null || ~/.local/bin/alr --version 2>/dev/null
```

If not installed, use the method for the detected OS.

## macOS
```bash
ALR_URL=$(curl -fsSL https://api.github.com/repos/alire-project/alire/releases/latest \
  | grep -o '"browser_download_url": "[^"]*bin-universal-macos[^"]*"' \
  | grep -o 'https://[^"]*')
curl -fsSL "$ALR_URL" -o /tmp/alr.zip
unzip /tmp/alr.zip -d /tmp/alr-bin
mkdir -p ~/.local/bin
mv /tmp/alr-bin/bin/alr ~/.local/bin/alr
chmod +x ~/.local/bin/alr
```

## Linux (Debian/Ubuntu)
```bash
ALR_URL=$(curl -fsSL https://api.github.com/repos/alire-project/alire/releases/latest \
  | grep -o '"browser_download_url": "[^"]*bin-x86_64-linux[^"]*"' \
  | grep -o 'https://[^"]*')
curl -fsSL "$ALR_URL" -o /tmp/alr.zip
unzip /tmp/alr.zip -d /tmp/alr-bin
mkdir -p ~/.local/bin
mv /tmp/alr-bin/bin/alr ~/.local/bin/alr
chmod +x ~/.local/bin/alr
```

## Windows
```powershell
if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install alire
} else {
    $release = Invoke-RestMethod https://api.github.com/repos/alire-project/alire/releases/latest
    $url = ($release.assets | Where-Object { $_.name -like "*installer-x86_64-windows*" }).browser_download_url
    Invoke-WebRequest $url -OutFile "$env:TEMP\alr-installer.exe"
    Start-Process "$env:TEMP\alr-installer.exe" -Wait
}
```

## Verify
```bash
alr --version
```

If installation fails, stop and inform the user — do not proceed without a working `alr`.
