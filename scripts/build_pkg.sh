#!/bin/bash
# MacRAR kurulum paketini (.pkg) üretir.  Kullanım: scripts/build_pkg.sh
#   SKIP_APP_BUILD=1     build/MacRAR.app zaten hazırsa yeniden derlemez
#   PKG_SIGN_IDENTITY=…  ("Developer ID Installer: …") verilirse paket imzalanır; yoksa imzasız üretilir
# Çıktı: build/MacRAR-<sürüm>.pkg, .sha256, KURULUM.txt, INSTALL.txt, uninstall.sh ve LICENSE.txt (dağıtımla birlikte verilecekler)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${SKIP_APP_BUILD:-0}" != "1" ]]; then
  UNIVERSAL=1 scripts/build_app.sh release
fi
APP="build/MacRAR.app"
[[ -d "$APP" ]] || { echo "HATA: $APP yok"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="build/MacRAR-$VERSION.pkg"

echo "▸ Paket içeriği hazırlanıyor ($VERSION)…"
STAGE="build/pkg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/payload" "$STAGE/resources"
ditto "$APP" "$STAGE/payload/MacRAR.app"
find "$STAGE/payload" -name .DS_Store -delete

# Uygulama başka bir yerde (örn. geliştirme klasöründe) bulunan bir kopyaya "taşınmasın": her zaman /Applications.
pkgbuild --analyze --root "$STAGE/payload" "$STAGE/component.plist" >/dev/null
/usr/bin/plutil -replace 0.BundleIsRelocatable -bool NO "$STAGE/component.plist"
/usr/bin/plutil -replace 0.BundleHasStrictIdentifier -bool NO "$STAGE/component.plist"
# Kurulum aynı/eski sürümün üzerine de uygulamayı her zaman yazsın (sürüm denetimiyle sessizce atlamasın).
/usr/bin/plutil -replace 0.BundleIsVersionChecked -bool NO "$STAGE/component.plist"

echo "▸ Bileşen paketi…"
# Not: bu macOS sürümünde pkgbuild, içerikten bağımsız olarak 4 kez "write: Permission denied" yazıyor
# (tek dosyalık boş bir yükte de çıkıyor); zararsız olduğundan yalnızca bu satır süzülür.
pkgbuild --root "$STAGE/payload" \
         --component-plist "$STAGE/component.plist" \
         --identifier local.macrar.pkg --version "$VERSION" \
         --install-location /Applications \
         --scripts scripts/pkg/scripts \
         "$STAGE/MacRAR-component.pkg" >/dev/null 2> >(grep -v '^write: Permission denied$' >&2)

echo "▸ Kurulum paketi (adım adım pencereli)…"
# Karşılama/okubeni/bitiş sayfaları iki dili alt alta içerir (Installer sayfaları biçimli metne çevirir; tıklanabilir
# dil seçici çalışmaz). Installer sistemin diline uyan klasörü seçer; o klasördeki sayfada o dil üstte durur.
for lang in tr en; do
  mkdir -p "$STAGE/resources/$lang.lproj"
  for page in scripts/pkg/resources/*.html; do
    python3 -I - "$page" "$lang" "$STAGE/resources/$lang.lproj/$(basename "$page")" <<'PY'
import re, sys
src, lang, out = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
page, rest = text.split("</body></html>", 1)
blocks = {k: re.search(rf"<!--{k}-->\n(.*?)<!--/{k}-->", rest, re.S).group(1) for k in ("TR", "EN")}
first, second = ("TR", "EN") if lang == "tr" else ("EN", "TR")
body = blocks[first] + "<hr>\n" + blocks[second]
open(out, "w", encoding="utf-8").write(page.replace("@LANG@", lang).replace("@BODY@", body.strip()) + "</body></html>\n")
PY
  done
done
sed "s/@VERSION@/$VERSION/g" scripts/pkg/distribution.xml > "$STAGE/distribution.xml"
SIGN_ARGS=()
if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then SIGN_ARGS=(--sign "$PKG_SIGN_IDENTITY"); fi
rm -f "$OUT"
productbuild --distribution "$STAGE/distribution.xml" --resources "$STAGE/resources" \
             --package-path "$STAGE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$OUT" >/dev/null

# Hazırlık klasöründeki uygulama kopyası sistemde "ikinci bir MacRAR" olarak kalmasın: kaydını sil, klasörü kaldır.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$STAGE/payload/MacRAR.app" >/dev/null 2>&1 || true
rm -rf "${STAGE:?}"

# Dağıtımla birlikte verilecek yardım dosyaları
sed "s/<sürüm>/$VERSION/g" scripts/pkg/KURULUM.txt > build/KURULUM.txt
sed "s/<version>/$VERSION/g" scripts/pkg/INSTALL.txt > build/INSTALL.txt
cp scripts/uninstall.sh build/uninstall.sh
cp LICENSE build/LICENSE.txt
( cd build && shasum -a 256 "MacRAR-$VERSION.pkg" > "MacRAR-$VERSION.pkg.sha256" )

echo "✔ Hazır: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  SHA-256: $(cut -d' ' -f1 "build/MacRAR-$VERSION.pkg.sha256")"
if [[ -z "${PKG_SIGN_IDENTITY:-}" ]]; then echo "  Not: paket imzasız; ilk açılışta Sistem Ayarları ▸ Gizlilik ve Güvenlik ▸ \"Yine de Aç\" gerekir (bkz. build/KURULUM.txt)."; fi
