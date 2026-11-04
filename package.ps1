$ErrorActionPreference = "Stop"

$extensionRoot = $PSScriptRoot
$bridgeRoot = Join-Path $extensionRoot "mcp-bridge"
$nodeModules = Join-Path $bridgeRoot "node_modules"
$outputPath = Join-Path $extensionRoot "codex-aseprite.aseprite-extension.zip"

if (-not (Test-Path (Join-Path $nodeModules "@modelcontextprotocol\sdk"))) {
    throw "MCP dependencies are missing. Run npm install in mcp-bridge first."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (Test-Path $outputPath) {
    Remove-Item -LiteralPath $outputPath -Force
}

$archive = [System.IO.Compression.ZipFile]::Open(
    $outputPath,
    [System.IO.Compression.ZipArchiveMode]::Create
)

try {
    $files = @(
        (Join-Path $extensionRoot "package.json"),
        (Join-Path $extensionRoot "main.lua")
    )
    $files += Get-ChildItem -LiteralPath $bridgeRoot -File -Recurse |
        ForEach-Object { $_.FullName }

    foreach ($file in $files) {
        $entryPath = $file.Substring($extensionRoot.Length).TrimStart("\", "/")
        $entryPath = $entryPath.Replace("\", "/")
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $file,
            $entryPath,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
}
finally {
    $archive.Dispose()
}

Write-Output "Created Aseprite extension package: $outputPath"
