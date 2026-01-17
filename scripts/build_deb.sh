#!/bin/bash
set -e

# Build Debian package locally using Docker
# This script mimics the CI/CD build process for local testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_IMAGE="debian:bookworm"

echo "Building Debian package locally..."

# Check if Docker is available
if ! command -v docker &> /dev/null; then
  echo "Error: Docker is not installed or not in PATH"
  exit 1
fi

# Run build in Docker container
docker run --rm \
  -v "$PROJECT_DIR:/workspace" \
  -w /workspace \
  "$BUILD_IMAGE" \
  bash -c '
    set -e

    echo "Installing build dependencies..."
    apt-get update -qq
    apt-get install -y -qq \
      debhelper \
      devscripts \
      build-essential \
      git

    echo "Installing package build dependencies..."
    apt-get build-dep -y . || true

    echo "Generating changelog..."
    pkgname=libpve-storage-purestorage-perl
    tag_list=$(git tag -l | grep -ve "-rc\.[0-9]$" | grep -ve "-beta\.[0-9]$" | sort -V)

    if [ -z "$tag_list" ]; then
      echo "Warning: No tags found, using default version"
      echo "$pkgname (0.0.1-1) stable; urgency=medium" > debian/changelog
      echo "" >> debian/changelog
      echo "  * Initial release" >> debian/changelog
      echo "" >> debian/changelog
      echo " -- Local Build <build@localhost>  $(date -R)" >> debian/changelog
    else
      prevtag=""
      for tag in ${tag_list}; do
        tag_header="$tag^..$tag"
        tag_info=$prevtag..$tag
        tag_version=$(echo $tag | cut -c2-)-1

        if [[ "$prevtag" == "" ]]; then
          tag_header="$tag"
          tag_info="$tag"
        elif [[ "$tag" == "$prevtag" ]]; then
          continue
        fi

        echo >> changelog
        git log --pretty="format: -- %aN <%aE>  %aD%n%n" $tag_header >> changelog
        git log --pretty=format:"  * %s%n" $tag_info >> changelog
        echo "" >> changelog
        echo "$pkgname ($tag_version) stable; urgency=medium" >> changelog

        prevtag=$tag
      done

      tac changelog > debian/changelog
    fi

    echo "Building package..."
    dpkg-buildpackage -us -uc -b

    echo "Generating checksums..."
    cd ..
    sha256sum *.deb > sha256sums 2>/dev/null || true

    echo "Moving files to build output directory..."
    mkdir -p /workspace/build
    mv *.deb *.buildinfo *.changes sha256sums /workspace/build/ 2>/dev/null || true

    echo "Build complete!"
    echo ""
    echo "Generated files:"
    ls -lh /workspace/build/
  '

echo ""
echo "Package built successfully!"
echo "Output files are in the build/ directory:"
ls -lh "$PROJECT_DIR"/build/*.deb 2>/dev/null || echo "No .deb files found"
