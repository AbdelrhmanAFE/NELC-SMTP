set -euo pipefail

PROJECT="nelc-futurex-prod"

echo "🔐 Fetching Exchange password once..."
SECRET=$(gcloud secrets versions access latest --secret=nelc-email-password --project="$PROJECT")
ESCAPED_SECRET_B64=$(printf '%s' "$SECRET" | base64)

# map of vm -> zone
declare -A LARAVEL_VMS_ZONES=(
  ["nelc-laravel-stage"]="me-central2-c"
  # add more VMs here, example:
  # ["nelc-laravel-prod"]="me-central2-b"
)

# map of vm -> env file (per-VM)
declare -A LARAVEL_ENV_PATHS=(
  ["nelc-laravel-stage"]="/var/www/html/laravel/multiversity/frontend/pre/.env"
  # add more explicit paths here
  # ["nelc-laravel-prod"]="/var/www/html/laravel/multiversity/frontend/.env"
)

for vm in "${!LARAVEL_VMS_ZONES[@]}"; do
  zone="${LARAVEL_VMS_ZONES[$vm]}"
  env_file="${LARAVEL_ENV_PATHS[$vm]:-/var/www/html/.env}"
  echo "🔧 Updating Laravel on $vm ($zone)... ENV file: $env_file"

  # Pass the base64 secret and the target ENV_FILE into the sudoed remote shell.
  # Using single quotes around the heredoc delimiter prevents local expansion of the body.
  gcloud compute ssh "$vm" \
    --zone="$zone" \
    --tunnel-through-iap \
    --project="$PROJECT" \
    --command="sudo B64='${ESCAPED_SECRET_B64}' ENV_FILE='${env_file}' bash -s" <<'REMOTE'
set -euo pipefail

# remote environment: $B64 and $ENV_FILE are set by the command invocation
KEY="MAIL_PASSWORD"
TS=$(date +%s)

# decode secret
SECRET=$(printf "%s" "$B64" | base64 -d)

if [ ! -f "$ENV_FILE" ]; then
  echo "WARNING: ENV file not found: $ENV_FILE"
  exit 0
fi

echo "Processing: $ENV_FILE"
cp -p "$ENV_FILE" "${ENV_FILE}.bak.$TS"

TMP=$(mktemp) || { echo "mktemp failed"; exit 1; }

# If the key exists replace it, otherwise append it at the end
if grep -q "^${KEY}=" "$ENV_FILE"; then
  awk -v sec="$SECRET" -v key="$KEY" '
    BEGIN{repl=0}
    $0 ~ ("^" key "=") { print key"=\""sec"\""; repl=1; next }
    { print }
    END { if (!repl) print key"=\""sec"\"" }
  ' "$ENV_FILE" > "$TMP"
else
  # preserve original then append
  cat "$ENV_FILE" > "$TMP"
  printf "\n%s=\"%s\"\n" "$KEY" "$SECRET" >> "$TMP"
fi

# atomic move and preserve perms
mv "$TMP" "$ENV_FILE"
chown --reference="${ENV_FILE}.bak.$TS" "$ENV_FILE" 2>/dev/null || true
chmod --reference="${ENV_FILE}.bak.$TS" "$ENV_FILE" 2>/dev/null || true

echo "Updated $ENV_FILE (backup: ${ENV_FILE}.bak.$TS)"

# Restart apache if available (ignore errors)
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart apache2 || echo "apache2 restart failed or service not found"
fi

REMOTE

done

echo "Done."
