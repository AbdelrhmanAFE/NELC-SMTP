#!/usr/bin/env bash
set -euo pipefail

PROJECT="nelc-futurex-prod"

echo "🔐 Fetching Exchange password once..."
SECRET=$(gcloud secrets versions access latest --secret=nelc-email-password --project="$PROJECT")
ESCAPED_SECRET_B64=$(printf '%s' "$SECRET" | base64)

# map of vm -> zone
declare -A LARAVEL_VMS_ZONES=(
  ["nelc-laravel-stage"]="me-central2-c"
)

# map of vm -> env file (per-VM)
declare -A LARAVEL_ENV_PATHS=(
  ["nelc-laravel-stage"]="/var/www/html/laravel/multiversity/frontend/pre/.env"
)

for vm in "${!LARAVEL_VMS_ZONES[@]}"; do
  zone="${LARAVEL_VMS_ZONES[$vm]}"
  env_file="${LARAVEL_ENV_PATHS[$vm]:-/var/www/html/.env}"
  echo "🔧 Updating Laravel on $vm ($zone)... ENV file: $env_file"

  gcloud compute ssh "$vm" \
    --zone="$zone" \
    --tunnel-through-iap \
    --project="$PROJECT" \
    --command="sudo B64='${ESCAPED_SECRET_B64}' ENV_FILE='${env_file}' bash -s" <<'REMOTE'
set -euo pipefail

KEY="MAIL_PASSWORD"
TS=$(date +%s)

# decode secret
SECRET=$(printf "%s" "$B64" | base64 -d)

if [ ! -f "$ENV_FILE" ]; then
  echo "WARNING: ENV file not found: $ENV_FILE"
  exit 0
fi

# cd into directory of env file
ENV_DIR=$(dirname "$ENV_FILE")
ENV_BASENAME=$(basename "$ENV_FILE")
cd "$ENV_DIR"

# delete only old backups we created earlier (.env.bak.build.*)
echo "🧹 Cleaning old backups in $ENV_DIR"
rm -f "${ENV_BASENAME}.bak.build."*

# create new backup with unique name
cp -p "$ENV_BASENAME" "${ENV_BASENAME}.bak.build.$TS"

TMP=$(mktemp) || { echo "mktemp failed"; exit 1; }

# If the key exists replace it, otherwise append it
if grep -q "^${KEY}=" "$ENV_BASENAME"; then
  awk -v sec="$SECRET" -v key="$KEY" '
    BEGIN{repl=0}
    $0 ~ ("^" key "=") { print key"=\""sec"\""; repl=1; next }
    { print }
    END { if (!repl) print key"=\""sec"\"" }
  ' "$ENV_BASENAME" > "$TMP"
else
  # preserve original then append
  cat "$ENV_BASENAME" > "$TMP"
  printf "\n%s=\"%s\"\n" "$KEY" "$SECRET" >> "$TMP"
fi

# atomic move and preserve perms
mv "$TMP" "$ENV_BASENAME"
chown --reference="${ENV_BASENAME}.bak.build.$TS" "$ENV_BASENAME" 2>/dev/null || true
chmod --reference="${ENV_BASENAME}.bak.build.$TS" "$ENV_BASENAME" 2>/dev/null || true

echo "✅ Updated $ENV_BASENAME (backup: ${ENV_BASENAME}.bak.build.$TS)"

# Restart apache if available
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart apache2 || echo "apache2 restart failed or service not found"
fi

REMOTE

done

echo "🎉 Done."
