#!/usr/bin/env bash
cd "$(dirname "$0")"
source ./script/setup.sh

build_version="0.1.0"
codesign_identity="hyprmac-codesign-certificate"
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --codesign-identity) codesign_identity="$2"; shift 2;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done

#############
### BUILD ###
#############

./build-docs.sh --release
./build-shell-completion.sh

./generate.sh
./script/check-uncommitted-files.sh

build_info_file="$PWD/.build-info.txt"
printf '%s\n%s\n%s\n' "$build_version" "$(git rev-parse HEAD)" "$(git rev-parse --short HEAD)" > "$build_info_file"

# Apple Silicon only: dropping x86_64 halves the release build time
swift_build_cli=(build -c release --arch arm64 --product hyprmac)
swift "${swift_build_cli[@]}" -Xswiftc -warnings-as-errors \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __aero_build \
    -Xlinker "$build_info_file"
cli_bin_path="$(swift "${swift_build_cli[@]}" --show-bin-path)"

rm -rf .release && mkdir .release

cd ./xcode
    xcode_configuration="Release"
    xcodebuild -version
    xcodebuild-pretty ../.release/xcodebuild.log clean build \
        -scheme HyprMac \
        -destination "generic/platform=macOS" \
        -configuration "$xcode_configuration" \
        -derivedDataPath .xcode-build \
        MARKETING_VERSION="$build_version" \
        ARCHS=arm64 \
        HYPRMAC_CODE_SIGN_IDENTITY="$codesign_identity" \
        HYPRMAC_BUILD_INFO_LDFLAGS="-sectcreate __TEXT __aero_build $build_info_file"
cd -

cp -r "xcode/.xcode-build/Build/Products/$xcode_configuration/HyprMac.app" .release
cp -r "$cli_bin_path/hyprmac" .release

# Binary reproducibility: strip non-portable rpaths
# https://github.com/swiftlang/swift-package-manager/issues/10760
xcrun objdump --macho --rpaths --no-leading-headers --arch all .release/hyprmac | grep -vE '^(@|/usr/lib/swift$)' | sort -u |
    while IFS= read -r rpath; do
        install_name_tool -delete_rpath "$rpath" .release/hyprmac
    done

################
### SIGN CLI ###
################

codesign -s "$codesign_identity" .release/hyprmac

################
### VALIDATE ###
################

./script/validate-release-binaries.sh

############
### PACK ###
############

mkdir -p ".release/HyprMac-$build_version/manpage" && cp .man/*.1 ".release/HyprMac-$build_version/manpage"
cp -r ./legal ".release/HyprMac-$build_version/legal"
cp -r .shell-completion ".release/HyprMac-$build_version/shell-completion"
cd .release
    mkdir -p "HyprMac-$build_version/bin" && cp -r hyprmac "HyprMac-$build_version/bin"
    cp -r HyprMac.app "HyprMac-$build_version"
    zip -r "HyprMac-$build_version.zip" "HyprMac-$build_version"
cd -

#################
### Brew Cask ###
#################
for cask_name in hyprmac hyprmac-dev; do
    ./script/build-brew-cask.sh \
        --cask-name "$cask_name" \
        --zip-uri ".release/HyprMac-$build_version.zip" \
        --build-version "$build_version"
done
