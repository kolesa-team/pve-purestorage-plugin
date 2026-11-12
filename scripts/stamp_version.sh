#!/bin/bash
set -euo pipefail

# Stamp a release version into the plugin, where it goes into the User-Agent of FlashArray requests.
# Usage: stamp_version.sh <version> [file]
# The version is a release tag without the leading "v": 1.2.3, 1.2.3-rc.1 or 1.2.3-beta.1.
# The source keeps an empty version, so a copy that is not stamped sends none.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="${1:-}"
file="${2:-$SCRIPT_DIR/../PureStoragePlugin.pm}"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(rc|beta)\.[0-9]+)?$ ]]; then
  echo "Error: '$version' is not a release version (expected 1.2.3, 1.2.3-rc.1 or 1.2.3-beta.1)" >&2
  exit 1
fi

if [ "$(grep -c "^our \$PLUGIN_VERSION = '';" "$file")" -ne 1 ]; then
  echo "Error: $file must have exactly one line \"our \$PLUGIN_VERSION = '';\" to stamp" >&2
  exit 1
fi

sed "s/^our \$PLUGIN_VERSION = '';/our \$PLUGIN_VERSION = '$version';/" "$file" > "$file.stamped"
mv "$file.stamped" "$file"

grep --quiet "^our \$PLUGIN_VERSION = '$version';" "$file"
echo "Stamped version $version into $file"
