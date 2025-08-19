#!/usr/bin/env bash
set -euo pipefail

PROJECT="nelc-futurex-prod"

echo "🔐 Fetching Exchange password once..."
SECRET=$(gcloud secrets versions access latest --secret=nelc-email-password --project="$PROJECT")
ESCAPED_SECRET_B64=$(printf '%s' "$SECRET" | base64)

# map of vm -> zone
declare -A DRUPAL_VMS_ZONES=(
  ["nelc-app-deployment"]="me-central2-b"
)

# map of vm -> settings.local.php (per-VM)
declare -A DRUPAL_SETTINGS_PATHS=(
  ["nelc-app-deployment"]="/var/www/nelc/web/sites/default/settings.local.php"
)

for vm in "${!DRUPAL_VMS_ZONES[@]}"; do
  zone="${DRUPAL_VMS_ZONES[$vm]}"
  settings_file="${DRUPAL_SETTINGS_PATHS[$vm]}"
  echo "🔧 Updating Drupal on $vm ($zone)... Settings file: $settings_file"

  gcloud compute ssh "$vm" \
    --zone="$zone" \
    --tunnel-through-iap \
    --project="$PROJECT" \
    --command="sudo B64='${ESCAPED_SECRET_B64}' SETTINGS_FILE='${settings_file}' bash -s" <<'REMOTE'
set -euo pipefail

TS=$(date +%s)
KEY="\$config['smtp.settings']['smtp_password']"

# decode secret
SECRET=$(printf "%s" "$B64" | base64 -d)

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "WARNING: Settings file not found: $SETTINGS_FILE"
  exit 0
fi

# cd into settings.php dir
SETTINGS_DIR=$(dirname "$SETTINGS_FILE")
SETTINGS_BASENAME=$(basename "$SETTINGS_FILE")
cd "$SETTINGS_DIR"

# delete only old backups we created earlier
echo "🧹 Cleaning old backups in $SETTINGS_DIR"
rm -f "${SETTINGS_BASENAME}.bak.build."*

# create new backup
cp -p "$SETTINGS_BASENAME" "${SETTINGS_BASENAME}.bak.build.$TS"

TMP=$(mktemp) || { echo "mktemp failed"; exit 1; }

# update or append the smtp_password line
if grep -q "\$config\['smtp.settings'\]\['smtp_password'\]" "$SETTINGS_BASENAME"; then
  sed -E "s|(\$config\['smtp.settings'\]\['smtp_password'\]\s*=\s*).*$|\1'$SECRET';|" "$SETTINGS_BASENAME" > "$TMP"
else
  cat "$SETTINGS_BASENAME" > "$TMP"
  printf "\n\$config['smtp.settings']['smtp_password'] = '%s';\n" "$SECRET" >> "$TMP"
fi

# atomic replace
mv "$TMP" "$SETTINGS_BASENAME"
chown --reference="${SETTINGS_BASENAME}.bak.build.$TS" "$SETTINGS_BASENAME" 2>/dev/null || true
chmod --reference="${SETTINGS_BASENAME}.bak.build.$TS" "$SETTINGS_BASENAME" 2>/dev/null || true

echo "✅ Updated $SETTINGS_BASENAME (backup: ${SETTINGS_BASENAME}.bak.build.$TS)"

# clear Drupal cache if drush is present
if command -v drush >/dev/null 2>&1; then
  echo "🔄 Clearing Drupal cache with drush"
  drush cr || echo "⚠️ drush cache rebuild failed"
fi

REMOTE

done

echo "🎉 Done."
