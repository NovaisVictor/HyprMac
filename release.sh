#!/usr/bin/env bash
cd "$(dirname "$0")"
source ./script/setup.sh

usage="Usage: ./release.sh <version> [--local]

Releases HyprMac <version> (e.g. 0.1.2) from HEAD of main, which must be pushed:
- by default on GitHub Actions (.github/workflows/release.yml)
- with --local, on this machine. Faster; it publishes with your gh and git credentials"

version=''
local=0
while test $# -gt 0; do
    case $1 in
        --local) local=1; shift ;;
        -h|--help) echo "$usage"; exit 0 ;;
        -*) echo "Unknown option $1" > /dev/stderr; echo "$usage" > /dev/stderr; exit 1 ;;
        *)
            if test -n "$version"; then echo "$usage" > /dev/stderr; exit 1; fi
            version=$1; shift ;;
    esac
done

fail() { echo "ERROR: $1" > /dev/stderr; exit 1; }

test -n "$version" || { echo "$usage" > /dev/stderr; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must look like 0.1.2, got '$version'"

test "$(git symbolic-ref --short HEAD)" = main || fail "releases are made from main"
test -z "$(git status --porcelain)" || fail "the working tree has uncommitted changes"
git fetch --quiet origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" || fail "HEAD isn't origin/main, push or pull first"
if git ls-remote --exit-code --tags origin "refs/tags/v$version" > /dev/null; then
    fail "v$version already exists"
fi
case "$(gh repo view --json viewerPermission -q .viewerPermission)" in
    ADMIN|MAINTAIN|WRITE) ;;
    *) fail "the active gh account can't publish to this repo (gh auth switch)" ;;
esac

if test $local == 1; then
    # setup.sh links them into .deps/bin only when they are installed. The CI installs them with brew
    for tool in fish cargo bundler; do
        test -x ".deps/bin/$tool" || fail "--local needs $tool, used by build-shell-completion.sh and build-docs.sh (brew install fish rust ruby)"
    done
    ./build-release.sh --build-version "$version" --codesign-identity -
    ./script/publish-release.sh "$version" ".release/HyprMac-$version.zip"
else
    gh workflow run release.yml --ref main -f version="$version"
    echo "Release $version started on GitHub Actions: $(gh repo view --json url -q .url)/actions/workflows/release.yml"
fi
