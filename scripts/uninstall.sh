#!/bin/bash
# MacRAR'ı kaldırır.  Kullanım: bash uninstall.sh
# Yalnızca açık, sabit yolları siler (joker karakter yok). Ayarlar ve parolalar için ayrıca sorar.
set -u

APP="/Applications/MacRAR.app"
EXT="$APP/Contents/PlugIns/MacRARFinder.appex"
EXT_ID="local.macrar.app.FinderSync"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DATA_DIR="$HOME/Library/Application Support/MacRAR"
VAULT_SERVICE="local.macrar.password-manager"

ask() { local r; read -r -p "$1 [e/H] " r; [[ "$r" =~ ^[eEyY]$ ]]; }

echo "MacRAR kaldırılıyor."
[[ -d "$APP" ]] || echo "Not: $APP bulunamadı (zaten kaldırılmış olabilir); kalan kayıtlar temizlenecek."
ask "Devam edilsin mi?" || { echo "İptal edildi."; exit 0; }

# 1) Çalışıyorsa kapat
/usr/bin/pkill -x MacRAR 2>/dev/null && echo "• MacRAR kapatıldı"

# 2) Finder eklentisini ve sistem kayıtlarını kaldır
/usr/bin/pluginkit -r "$EXT" 2>/dev/null; /usr/bin/pluginkit -e ignore -i "$EXT_ID" 2>/dev/null
[[ -d "$APP" ]] && "$LSREGISTER" -u "$APP" 2>/dev/null
echo "• Finder eklentisi ve sistem kayıtları kaldırıldı"

# 3) Uygulamayı sil (kurulum paketi yönetici sahipli kurduğundan sudo gerekir)
if [[ -d "$APP" ]]; then
  if [[ -w "$APP" ]]; then rm -rf "$APP"; else echo "• Yönetici parolası istenebilir:"; sudo rm -rf "$APP"; fi
  [[ -d "$APP" ]] && echo "HATA: $APP silinemedi" || echo "• $APP silindi"
fi

# 4) İsteğe bağlı: ayarlar, gizli anahtar ve kayıtlı parolalar
if ask "Ayarlar ve Finder gizli anahtarı da silinsin mi?"; then
  /usr/bin/defaults delete local.macrar.app 2>/dev/null
  [[ -d "$DATA_DIR" ]] && rm -rf "$DATA_DIR"
  echo "• Ayarlar ve gizli anahtar silindi"
fi
if ask "Parola yöneticisindeki KAYITLI PAROLALAR (Anahtar Zinciri) silinsin mi? Bu geri alınamaz."; then
  /usr/bin/security delete-generic-password -s "$VAULT_SERVICE" >/dev/null 2>&1 && echo "• Kayıtlı parolalar silindi" || echo "• Kayıtlı parola bulunamadı"
fi

# 5) Kurulum kaydı ve Finder
sudo /usr/sbin/pkgutil --forget local.macrar.pkg >/dev/null 2>&1 && echo "• Kurulum kaydı silindi"
/usr/bin/killall Finder 2>/dev/null && echo "• Finder yeniden başlatıldı"
echo "Tamam. MacRAR kaldırıldı."
