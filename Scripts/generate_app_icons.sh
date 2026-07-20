#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
source_artwork="$repository_root/Documentation/Artwork/PortPilotIconSource.png"
destination="$repository_root/PortPilot/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$source_artwork" ]]; then
  print -u2 "Missing source artwork: $source_artwork"
  exit 1
fi

typeset -A sizes=(
  icon_16x16.png 16
  icon_16x16@2x.png 32
  icon_32x32.png 32
  icon_32x32@2x.png 64
  icon_128x128.png 128
  icon_128x128@2x.png 256
  icon_256x256.png 256
  icon_256x256@2x.png 512
  icon_512x512.png 512
  icon_512x512@2x.png 1024
)

for filename pixels in ${(kv)sizes}; do
  /usr/bin/sips --resampleHeightWidth "$pixels" "$pixels" "$source_artwork" --out "$destination/$filename" >/dev/null
done

print "Generated macOS icon assets in $destination"

