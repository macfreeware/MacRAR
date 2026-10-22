#!/bin/bash
# MacRAR.app paketini üretir.  Kullanım: scripts/build_app.sh [release|debug]
# UNIVERSAL=1 ortam değişkeni ile arm64+x86_64 evrensel ikili üretilir.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "▸ Derleniyor ($CONFIG)…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/MacRAR"

APP="build/MacRAR.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacRAR"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE"
# Çeviriler: Türkçe kaynak dil, İngilizce çeviri (bkz. scripts/check_strings.sh)
cp -R Resources/*.lproj "$APP/Contents/Resources/"

echo "▸ UnRAR (ücretsiz) RARLAB'dan alınıyor…"
scripts/fetch_unrar.sh "$APP/Contents/Resources"

echo "▸ Simge üretiliyor…"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift scripts/make_icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Finder menü eklentisi derleniyor…"
EXT="$APP/Contents/PlugIns/MacRARFinder.appex"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
EXT_ARCHS=(arm64)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then EXT_ARCHS=(arm64 x86_64); fi
EXT_BINS=()
for arch in "${EXT_ARCHS[@]}"; do
  swiftc -O -target "$arch-apple-macos15.0" -parse-as-library -module-name MacRARFinder \
    -application-extension -framework FinderSync -framework Cocoa \
    FinderExtension/MacRARFinderSync.swift Sources/MacRARCore/FinderIntegration.swift Sources/MacRARCore/FinderToken.swift Sources/MacRARCore/FinderState.swift \
    -Xlinker -e -Xlinker _NSExtensionMain -o "build/MacRARFinder-$arch"
  EXT_BINS+=("build/MacRARFinder-$arch")
done
lipo -create "${EXT_BINS[@]}" -output "$EXT/Contents/MacOS/MacRARFinder"
cp scripts/FinderSync-Info.plist "$EXT/Contents/Info.plist"
# Menü metinleri uygulamayla aynı çeviri tablolarından; eklentinin kendi adı (Sistem Ayarları ▸ Eklentiler) ayrı.
for lproj in Resources/*.lproj; do
  lang="$(basename "$lproj")"
  mkdir -p "$EXT/Contents/Resources/$lang"
  cp "$lproj"/Localizable.* "$EXT/Contents/Resources/$lang/"
  cp "Resources/FinderExtension/$lang/InfoPlist.strings" "$EXT/Contents/Resources/$lang/"
done
sips -z 64 64 build/icon_1024.png --out "$EXT/Contents/Resources/MenuIcon.png" >/dev/null

# Gizli anahtar derleme sırasında ÜRETİLMEZ: her kurulumda uygulama ilk açılışta kendi anahtarını
# ~/Library/Application Support/MacRAR/finder.token dosyasına yazar (bkz. FinderToken.swift).
PB=/usr/libexec/PlistBuddy
# "Hakkında" penceresinde görünen derleme bilgisi: commit sayısı ve kısa commit özeti (git yoksa atlanır).
if git rev-parse --git-dir >/dev/null 2>&1; then
  BUILD_NO="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
  COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo)"
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && COMMIT="$COMMIT+"   # '+': commit'lenmemiş değişiklik var
  "$PB" -c "Set :CFBundleVersion $BUILD_NO" "$APP/Contents/Info.plist"
  "$PB" -c "Add :MacRARCommit string $COMMIT" "$APP/Contents/Info.plist"
fi

# SIGN_IDENTITY: gerçek bir imzalama kimliğinin adı (örn. "Apple Development: ad (TAKIMID)").
# Verilmezse ad-hoc ("-") imza kullanılır. Kimlikle imzalama, her derlemede AYNI kimliği verir; böylece
# Anahtar Zinciri'ndeki parola yöneticisi izni ("Her Zaman İzin Ver") güncellemelerde de geçerli kalır.
# Ad-hoc imzada kod özeti her derlemede değişir ve izin penceresi her güncellemeden sonra yeniden çıkar.
SIGN="${SIGN_IDENTITY:--}"
if [[ "$SIGN" == "-" ]]; then
  echo "▸ İmzalanıyor (ad-hoc; Anahtar Zinciri izni her güncellemede yeniden sorulur)…"
else
  echo "▸ İmzalanıyor ($SIGN)…"
fi
codesign --force --sign "$SIGN" --timestamp=none --entitlements scripts/FinderSync.entitlements "$EXT"
codesign --force --sign "$SIGN" --timestamp=none "$APP"

echo "✔ Hazır: $APP"

# build/ içindeki geliştirme kopyası Spotlight/Launch Services'e "ikinci bir MacRAR" olarak kaydolmasın
# (aynı kimlikli kopyalar "Birlikte aç" ve hizmetlerde çift girdiye yol açar).
touch build/.metadata_never_index
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" >/dev/null 2>&1 || true

# INSTALL=1: /Applications'a kopyalar ve Finder hizmetlerini (sağ tık menüsü) sisteme tanıtır.
if [[ "${INSTALL:-0}" == "1" ]]; then
  echo "▸ /Applications'a kuruluyor…"
  rm -rf "/Applications/MacRAR.app"
  cp -R "$APP" "/Applications/MacRAR.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/MacRAR.app"
  /System/Library/CoreServices/pbs -update || true
  pluginkit -a "/Applications/MacRAR.app/Contents/PlugIns/MacRARFinder.appex" || true
  echo "✔ Kuruldu."
  echo "  Finder ana sağ tık menüsü için eklentiyi bir kez etkinleştirin:"
  echo "  Sistem Ayarları → Genel → Oturum Açma Öğeleri ve Eklentiler → Eklentiler → Finder → MacRAR"
  echo "  (veya: pluginkit -e use -i local.macrar.app.FinderSync)"
  echo "  ÖNEMLİ: Her kurulum/güncellemeden sonra Finder'ı yeniden başlatın, aksi halde sağ tık menüsü kaybolur:  killall Finder"
fi
