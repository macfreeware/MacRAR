#!/bin/bash
# RARLAB'ın resmi "RAR for macOS" paketinden YALNIZCA ücretsiz UnRAR bileşenini (unrar + lisans/teşekkür metinleri)
# uygulamanın içine koyar.  Kullanım: scripts/fetch_unrar.sh <Resources klasörü>
#
# Lisans (license.txt, madde 3.a): "UnRAR bileşenleri" ayrı dağıtılabilir; rar'ın kendisi dağıtılamaz.
# Bu yüzden rar PAKETLENMEZ. Dosyalar RARLAB paketinden olduğu gibi (değiştirilmeden, yeniden imzalanmadan) alınır;
# indirilen paket sabitlenmiş SHA-256 ile doğrulanır.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:?kullanım: fetch_unrar.sh <Resources klasörü>}/unrar"

VERSION=723
ARM_SHA=68b393c000758d477fde43c955ff7542f12f76f3f5e87cdda923152fc791bd4d
X64_SHA=da1fb3c3d7748136c9b369b683d574b372cb1ed049a634a81f85d93918346d8f

CACHE="build/cache/rar-$VERSION"
mkdir -p "$CACHE"
rm -rf "$DEST"

for pair in "arm:$ARM_SHA" "x64:$X64_SHA"; do
  arch="${pair%%:*}"; want="${pair##*:}"
  tgz="$CACHE/rarmacos-$arch-$VERSION.tar.gz"
  if [[ ! -f "$tgz" ]] || [[ "$(shasum -a 256 "$tgz" | cut -d' ' -f1)" != "$want" ]]; then
    echo "  ↓ rarmacos-$arch-$VERSION.tar.gz (rarlab.com)"
    curl -sSfL --max-time 120 -o "$tgz" "https://www.rarlab.com/rar/rarmacos-$arch-$VERSION.tar.gz"
  fi
  got="$(shasum -a 256 "$tgz" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || { echo "HATA: $tgz SHA-256 uyuşmuyor ($got)"; rm -f "$tgz"; exit 1; }
  work="$(mktemp -d)"
  tar -xzf "$tgz" -C "$work"
  mkdir -p "$DEST/$arch"
  cp -p "$work/rar/unrar" "$work/rar/license.txt" "$work/rar/acknow.txt" "$DEST/$arch/"
  rm -rf "$work"
done
echo "  ✔ unrar $VERSION (arm + x64) → $DEST"
