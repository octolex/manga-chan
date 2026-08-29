#!/usr/bin/env bash
#
# Fetches the third-party specifications we develop against.
#
# These are deliberately not committed: Apple's specs are copyrighted, and
# putting them in a public repository is redistribution. See README.md.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apple"
mkdir -p "$root"

fetch() {
    local url="$1" name="$2"
    echo "Fetching $name..."
    curl -sSL --max-time 300 -o "$root/$name" "$url"
    echo "  $(du -h "$root/$name" | cut -f1)"
}

fetch "https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf" \
      "Metal-Shading-Language-Specification.pdf"
fetch "https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf" \
      "Metal-Feature-Set-Tables.pdf"
fetch "https://www.w3.org/TR/compositing-1/" \
      "W3C-Compositing-and-Blending-1.html"

echo
echo "Done. To read the PDFs as text:  python -m pip install pypdf"
