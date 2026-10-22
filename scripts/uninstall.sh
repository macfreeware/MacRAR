#!/bin/bash
# MacRAR'ı kaldırır / Uninstalls MacRAR.  Kullanım / Usage: bash uninstall.sh
# Yalnızca açık, sabit yolları siler (joker karakter yok). Ayarlar ve parolalar için ayrıca sorar.
# Mesajlar MacRAR'da seçilen dilde, seçilmemişse sistem dilinde; Türkçe dışındaki her dilde İngilizce.
set -u

APP="/Applications/MacRAR.app"
EXT="$APP/Contents/PlugIns/MacRARFinder.appex"
EXT_ID="local.macrar.app.FinderSync"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DATA_DIR="$HOME/Library/Application Support/MacRAR"
VAULT_SERVICE="local.macrar.password-manager"

# İlk tercih edilen dil: önce MacRAR'ın kendi seçimi (Ayarlar ▸ Genel ▸ Dil), sonra sistem.
first_lang() { /usr/bin/defaults read "$1" AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z-]//gp'; }
LANG_CODE="$(first_lang local.macrar.app)"
[[ -n "$LANG_CODE" ]] || LANG_CODE="$(first_lang -g)"
if [[ "$LANG_CODE" == tr* ]]; then TR=1; else TR=0; fi

# t "Türkçe" "English": dile uyan metni yazdırır.
t() { if (( TR )); then printf '%s' "$1"; else printf '%s' "$2"; fi; }
say() { echo "$(t "$1" "$2")"; }
# Evet: e/E (Türkçe) ya da y/Y (İngilizce); her iki dilde de ikisi de kabul edilir.
ask() { local r; read -r -p "$(t "$1 [e/H]" "$2 [y/N]") " r; [[ "$r" =~ ^[eEyY]$ ]]; }

say "MacRAR kaldırılıyor." "Uninstalling MacRAR."
[[ -d "$APP" ]] || say "Not: $APP bulunamadı (zaten kaldırılmış olabilir); kalan kayıtlar temizlenecek." \
                       "Note: $APP not found (it may already be removed); leftover records will be cleaned up."
ask "Devam edilsin mi?" "Continue?" || { say "İptal edildi." "Cancelled."; exit 0; }

# 1) Çalışıyorsa kapat
/usr/bin/pkill -x MacRAR 2>/dev/null && say "• MacRAR kapatıldı" "• MacRAR closed"

# 2) Finder eklentisini ve sistem kayıtlarını kaldır
/usr/bin/pluginkit -r "$EXT" 2>/dev/null; /usr/bin/pluginkit -e ignore -i "$EXT_ID" 2>/dev/null
[[ -d "$APP" ]] && "$LSREGISTER" -u "$APP" 2>/dev/null
say "• Finder eklentisi ve sistem kayıtları kaldırıldı" "• Finder extension and system records removed"

# 3) Uygulamayı sil (kurulum paketi yönetici sahipli kurduğundan sudo gerekir)
if [[ -d "$APP" ]]; then
  if [[ -w "$APP" ]]; then rm -rf "$APP"; else say "• Yönetici parolası istenebilir:" "• Your administrator password may be requested:"; sudo rm -rf "$APP"; fi
  [[ -d "$APP" ]] && say "HATA: $APP silinemedi" "ERROR: could not delete $APP" || say "• $APP silindi" "• $APP deleted"
fi

# 4) İsteğe bağlı: ayarlar, gizli anahtar ve kayıtlı parolalar
if ask "Ayarlar ve Finder gizli anahtarı da silinsin mi?" "Also delete settings and the Finder secret key?"; then
  /usr/bin/defaults delete local.macrar.app 2>/dev/null
  [[ -d "$DATA_DIR" ]] && rm -rf "$DATA_DIR"
  say "• Ayarlar ve gizli anahtar silindi" "• Settings and secret key deleted"
fi
if ask "Parola yöneticisindeki KAYITLI PAROLALAR (Anahtar Zinciri) silinsin mi? Bu geri alınamaz." \
       "Delete the SAVED PASSWORDS in the password manager (Keychain)? This cannot be undone."; then
  /usr/bin/security delete-generic-password -s "$VAULT_SERVICE" >/dev/null 2>&1 \
    && say "• Kayıtlı parolalar silindi" "• Saved passwords deleted" \
    || say "• Kayıtlı parola bulunamadı" "• No saved passwords found"
fi

# 5) Kurulum kaydı ve Finder
sudo /usr/sbin/pkgutil --forget local.macrar.pkg >/dev/null 2>&1 && say "• Kurulum kaydı silindi" "• Installer receipt removed"
/usr/bin/killall Finder 2>/dev/null && say "• Finder yeniden başlatıldı" "• Finder restarted"
say "Tamam. MacRAR kaldırıldı." "Done. MacRAR has been uninstalled."
