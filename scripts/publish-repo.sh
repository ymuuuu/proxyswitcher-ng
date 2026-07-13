#!/usr/bin/env bash
#
# Build (and sign) a Sileo/APT repo from one or more .deb files.
#
# Usage:
#   scripts/publish-repo.sh <repo_dir> <deb> [<deb> ...]
#
# <repo_dir> is the directory that will be served as the repo root, e.g.
# the MainBlog checkout's  public/repo  (served at https://ymuu.me/repo).
# Debs are copied into <repo_dir>/debs, then Packages / Release are
# regenerated and GPG-signed. Re-run it any time a new .deb is built.
#
# Requires: dpkg-scanpackages, gzip, bzip2, gpg. The signing key is selected
# by GPG_KEY (defaults to the repo key email below).

set -euo pipefail

GPG_KEY="${GPG_KEY:-fmemox5@gmail.com}"

REPO_ORIGIN="ymuu"
REPO_LABEL="ymuu repo"
REPO_SUITE="stable"
REPO_VERSION="1.0"
REPO_CODENAME="ios"
REPO_ARCHS="iphoneos-arm64"
REPO_COMPONENTS="main"
REPO_DESC="ProxySwitcher-ng and other bits by ymuu"

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <repo_dir> <deb> [<deb> ...]" >&2
    exit 1
fi

REPO_DIR="$1"; shift
mkdir -p "$REPO_DIR/debs"
for deb in "$@"; do
    cp -f "$deb" "$REPO_DIR/debs/"
done

cd "$REPO_DIR"

# Package index. -m keeps multiple versions if present.
dpkg-scanpackages -m debs /dev/null > Packages
gzip  -9 -c Packages > Packages.gz
bzip2 -9 -c Packages > Packages.bz2

# Release header.
{
    echo "Origin: $REPO_ORIGIN"
    echo "Label: $REPO_LABEL"
    echo "Suite: $REPO_SUITE"
    echo "Version: $REPO_VERSION"
    echo "Codename: $REPO_CODENAME"
    echo "Architectures: $REPO_ARCHS"
    echo "Components: $REPO_COMPONENTS"
    echo "Description: $REPO_DESC"
} > Release

# Hash sections (MD5Sum + SHA256) over the index files.
append_hashes() {
    local algo="$1" prog="$2"
    echo "$algo:" >> Release
    for f in Packages Packages.gz Packages.bz2; do
        local hash size
        hash=$($prog "$f" | awk '{print $1}')
        size=$(wc -c < "$f")
        printf ' %s %s %s\n' "$hash" "$size" "$f" >> Release
    done
}
append_hashes "MD5Sum" "md5sum"
append_hashes "SHA256" "sha256sum"

# Sign: detached (Release.gpg) + inline clearsigned (InRelease).
rm -f Release.gpg InRelease
gpg --default-key "$GPG_KEY" --batch --yes -abs  -o Release.gpg Release
gpg --default-key "$GPG_KEY" --batch --yes --clearsign -o InRelease Release

# Publish the public key so APT/Sileo can verify.
gpg --export --armor "$GPG_KEY" > ymuu-repo.asc

echo "repo built at: $REPO_DIR"
ls -la "$REPO_DIR"
