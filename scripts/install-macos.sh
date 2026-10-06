#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SOURCE="$(pwd)/dist/Translator.app"
DESTINATION="/Applications/Translator.app"
if [ ! -d "$SOURCE" ]; then
    printf 'Build first: ./scripts/build-macos.sh\n' >&2
    exit 1
fi
if [ ! -w /Applications ]; then
    printf 'Cannot write /Applications. Copy dist/Translator.app there using Finder.\n' >&2
    exit 1
fi
if [ -e "$DESTINATION" ]; then
    IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")
    if [ "$IDENTIFIER" != local.translator.codex ]; then
        printf 'An unrelated Translator.app already exists; installation stopped.\n' >&2
        exit 1
    fi
fi
codesign --verify --deep --strict "$SOURCE"
STAGING=$(mktemp -d /Applications/.translator-install.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$SOURCE" "$STAGING/Translator.app"
if [ -e "$DESTINATION" ]; then mv "$DESTINATION" "$STAGING/previous.app"; fi
if ! mv "$STAGING/Translator.app" "$DESTINATION"; then
    if [ -e "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$DESTINATION"; fi
    exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DESTINATION"
printf 'Installed: %s\n' "$DESTINATION"
