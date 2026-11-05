#!/usr/bin/env bash
cd "$(dirname "$0")/.."
source ./script/setup.sh

# Publishes a release built by build-release.sh: the GitHub release, which creates the v<version> tag on HEAD,
# and the Homebrew cask in the tap. Shared by .github/workflows/release.yml and `./release.sh --local`.
#
# Optional env:
# - HYPRMAC_TAP_REMOTE: git remote of the tap. Defaults to https, which uses your git credentials
# - HYPRMAC_TAP_AUTHOR_NAME, HYPRMAC_TAP_AUTHOR_EMAIL: author of the tap commit. Default to this repo's git user

if test $# -ne 2; then
    echo "Usage: $0 <version> <archive>" > /dev/stderr
    exit 1
fi
version=$1
archive=$2
if ! test -f "$archive"; then
    echo "ERROR: $archive doesn't exist. Run build-release.sh first" > /dev/stderr
    exit 1
fi

sha256=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
gh release create "v$version" "$archive" --target "$(git rev-parse HEAD)" --title "HyprMac $version" --generate-notes

tap_dir=$(mktemp -d)
trap 'rm -rf "$tap_dir"' EXIT
git clone --quiet --depth 1 "${HYPRMAC_TAP_REMOTE:-https://github.com/NovaisVictor/homebrew-tap.git}" "$tap_dir"
mkdir -p "$tap_dir/Casks"
sed -e "s/{{VERSION}}/$version/" -e "s/{{SHA256}}/$sha256/" packaging/hyprmac.rb.template > "$tap_dir/Casks/hyprmac.rb"
git -C "$tap_dir" add Casks/hyprmac.rb
git -C "$tap_dir" \
    -c user.name="${HYPRMAC_TAP_AUTHOR_NAME:-$(git config user.name)}" \
    -c user.email="${HYPRMAC_TAP_AUTHOR_EMAIL:-$(git config user.email)}" \
    commit --quiet -m "hyprmac $version"
git -C "$tap_dir" push --quiet

echo "Released HyprMac $version: brew update && brew upgrade --cask hyprmac"
