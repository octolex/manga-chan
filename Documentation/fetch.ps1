# Fetches the third-party specifications we develop against.
#
# These are deliberately not committed: Apple's specs are copyrighted, and
# putting them in a public repository is redistribution. See README.md.

$ErrorActionPreference = 'Stop'

$root = Join-Path $PSScriptRoot 'apple'
New-Item -ItemType Directory -Force -Path $root | Out-Null

$documents = @(
    @{ Url = 'https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf'
       Name = 'Metal-Shading-Language-Specification.pdf' },
    @{ Url = 'https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf'
       Name = 'Metal-Feature-Set-Tables.pdf' },
    @{ Url = 'https://www.w3.org/TR/compositing-1/'
       Name = 'W3C-Compositing-and-Blending-1.html' }
)

foreach ($document in $documents) {
    $destination = Join-Path $root $document.Name
    Write-Host "Fetching $($document.Name)..."
    Invoke-WebRequest -Uri $document.Url -OutFile $destination -UseBasicParsing
    $sizeMb = [math]::Round((Get-Item $destination).Length / 1MB, 1)
    Write-Host "  $sizeMb MB"
}

Write-Host ''
Write-Host 'Done. To read the PDFs as text:  python -m pip install pypdf'
