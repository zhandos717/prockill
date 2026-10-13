#!/bin/sh
# Собирает ProcKill.app с виджетом и подписывает сертификатом Apple Development.
# Без сертификата macOS не покажет виджет: App Group привязан к Team ID.
set -e
cd "$(dirname "$0")"

IDENTITY_HASH=${IDENTITY_HASH:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}
[ -n "$IDENTITY_HASH" ] || { echo "Нет сертификата Apple Development: войди в Xcode → Settings → Accounts"; exit 1; }
TEAM=${TEAM:-$(security find-certificate -a -Z -p | awk -v h="$IDENTITY_HASH" '
  /^SHA-1 hash:/ { found = ($3 == h) } found && /BEGIN/ { p = 1 } p { print } found && /END/ { exit }' \
  | openssl x509 -noout -subject | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')}
GROUP="$TEAM.kz.zhandos.prockill"
echo "Team $TEAM, App Group $GROUP"

mkdir -p build
xcodegen generate --quiet
xcodebuild -project ProcKill.xcodeproj -scheme ProcKill -configuration Release -derivedDataPath build/dd \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGNING_ALLOWED=NO -quiet -destination 'platform=macOS,arch=arm64'
rm -rf ProcKill.app && cp -R build/dd/Build/Products/Release/ProcKill.app .

ents() { # $1 path, $2 sandbox true/false
cat > "$1" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><$2/>
  <key>com.apple.security.application-groups</key><array><string>$GROUP</string></array>
</dict></plist>
ENT
}
# Расширение виджета обязано жить в песочнице; приложению песочница помешала бы видеть чужие процессы.
ents build/widget.entitlements true
ents build/app.entitlements false
codesign --force --sign "$IDENTITY_HASH" --entitlements build/widget.entitlements ProcKill.app/Contents/PlugIns/ProcKillWidget.appex
codesign --force --sign "$IDENTITY_HASH" --entitlements build/app.entitlements ProcKill.app
codesign --verify --deep --strict ProcKill.app
ProcKill.app/Contents/MacOS/ProcKill --selftest
