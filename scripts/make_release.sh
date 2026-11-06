#!/bin/bash
# Sürüm dosyalarını hazırlar: kurulum paketi (scripts/build_pkg.sh) ile build/release/MacRAR.zip + .sha256.
# Uygulamanın kendini güncellemesi bu iki sabit adı arar (bkz. Sources/MacRARCore/UpdateInfo.swift).
#
#   scripts/make_release.sh                       # yalnızca dosyaları hazırlar ve denetler
#   scripts/make_release.sh --publish notlar.md   # ayrıca GitLab'da v<sürüm> sürümünü oluşturur (glab ile);
#                                                 # notlardaki @PKG_SHA@ ve @ZIP_SHA@ doldurulur
#
# Sürüm numarası scripts/Info.plist'ten gelir; önce onu (sed ile, bkz. SONRAKI-SURUM.md) yükseltip commit'leyin.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
OUT="build/release"
PROJECT="freeware2%2Fmacrar"

scripts/build_pkg.sh
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --norsrc --noextattr --keepParent build/MacRAR.app "$OUT/MacRAR.zip"   # ._ dosyaları olmadan
(cd "$OUT" && shasum -a 256 MacRAR.zip > MacRAR.zip.sha256)

# Denetim: zip'ten çıkan uygulama, güncelleyicinin aradığı yerde, imzalı, evrensel ve doğru sürümde mi?
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$OUT/MacRAR.zip" "$CHECK"
APP="$CHECK/MacRAR.app"
EXT="$APP/Contents/PlugIns/MacRARFinder.appex"
codesign --verify --deep --strict "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXT/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(lipo -archs "$APP/Contents/MacOS/MacRAR")" == "x86_64 arm64" ]]
[[ "$(lipo -archs "$EXT/Contents/MacOS/MacRARFinder")" == "x86_64 arm64" ]]

# Finder eklentisi korumalı çalışır; yetkileri zip'ten sonra da durmalı.
codesign -d --entitlements - "$EXT" 2>/dev/null | grep -q "com.apple.security.app-sandbox"
codesign -d --entitlements - "$EXT" 2>/dev/null | grep -q "/Library/Application Support/MacRAR/"

# RARLAB lisansı rar'ın başka yazılımın içinde dağıtılmasına izin vermez; yalnızca unrar paketlenir.
if [[ -n "$(find "$APP" -name rar -type f)" ]]; then
  echo "✘ Zip'te rar var" >&2
  exit 1
fi

# Deneme ayarları (yalnızca DEBUG) yayımlanan ikilide olmamalı.
if strings build/MacRAR.app/Contents/MacOS/MacRAR | grep -q "MACRAR_UPDATE_"; then
  echo "✘ Yayım ikilisinde deneme ayarı var" >&2
  exit 1
fi

echo "✔ $OUT ($VERSION)"
cat "$OUT/MacRAR.zip.sha256" "build/MacRAR-$VERSION.pkg.sha256"

if [[ "${1:-}" == "--publish" ]]; then
  NOTES_SRC="${2:?Notlar dosyası gerekli: scripts/make_release.sh --publish notlar.md}"
  # Özetler bu derlemeye ait olmalı: notlardaki @PKG_SHA@ ve @ZIP_SHA@ burada doldurulur.
  NOTES="$OUT/notes.md"
  sed -e "s/@PKG_SHA@/$(cut -d' ' -f1 "build/MacRAR-$VERSION.pkg.sha256")/g" \
      -e "s/@ZIP_SHA@/$(cut -d' ' -f1 "$OUT/MacRAR.zip.sha256")/g" "$NOTES_SRC" > "$NOTES"
  glab release create "v$VERSION" \
    "$OUT/MacRAR.zip#MacRAR.zip" \
    "$OUT/MacRAR.zip.sha256#MacRAR.zip.sha256" \
    "build/MacRAR-$VERSION.pkg#MacRAR-$VERSION.pkg" \
    "build/MacRAR-$VERSION.pkg.sha256#MacRAR-$VERSION.pkg.sha256" \
    "build/INSTALL.txt#INSTALL.txt" "build/KURULUM.txt#KURULUM.txt" \
    "build/uninstall.sh#uninstall.sh" "build/LICENSE.txt#LICENSE.txt" \
    --ref main --name "MacRAR $VERSION" --notes-file "$NOTES"
  # README'deki indirme düğmesi ve MacExplorer sürümsüz adresi kullanır: .../permalink/latest/downloads/MacRAR.pkg
  ID="$(glab api "projects/$PROJECT/releases/v$VERSION/assets/links" |
        python3 -I -c 'import sys,json; print(next(l["id"] for l in json.load(sys.stdin) if l["name"].endswith(".pkg")))')"
  printf '{"name":"MacRAR-%s.pkg","direct_asset_path":"/MacRAR.pkg","link_type":"package"}' "$VERSION" |
    glab api --method PUT -H "Content-Type: application/json" --input - \
      "projects/$PROJECT/releases/v$VERSION/assets/links/$ID" >/dev/null
fi
