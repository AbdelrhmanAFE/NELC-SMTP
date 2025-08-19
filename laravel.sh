echo "🔐 Fetching Exchange password once..."
        gcloud secrets versions access latest --secret=nelc-email-password > /workspace/secret.txt
        SECRET=$(cat /workspace/secret.txt)

        declare -A LARAVEL_VMS_ZONES=(
          ["nelc-laravel-stage"]="me-central2-c"
        )
        declare -A LARAVEL_ENV_PATHS=(
          ["nelc-laravel-stage"]="/var/www/html/laravel/multiversity/frontend/pre/.env"
        )
        for vm in "${!LARAVEL_VMS_ZONES[@]}"; do
          zone="${LARAVEL_VMS_ZONES[$vm]}"
          env_file="${LARAVEL_ENV_PATHS[$vm]:-/var/www/html/.env}"
          echo "🔧 Updating Laravel on $vm ($zone)... ENV file: $env_file"

          ESCAPED_SECRET=$(printf "%s" "$SECRET" | sed 's/"/\\"/g')
echo $env_file
echo $ESCAPED_SECRET
gcloud compute ssh "$vm" \
  --zone="$zone" \
  --tunnel-through-iap \
  --project="nelc-futurex-prod" \
  --command="bash -c '
    KEY=\"MAIL_PASSWORD\"
    ENV_FILE=\"$env_file\"
    ESCAPED_SECRET=\"$ESCAPED_SECRET\"

    mkdir -p \"\$(dirname \"\$ENV_FILE\")\"

    if [ ! -f \"\$ENV_FILE\" ]; then
      echo \"# Laravel ENV file\" > \"\$ENV_FILE\"
    fi

    if grep -q \"^\\\$KEY=\" \"\\\$ENV_FILE\"; then
      sed -i \"s|^\\\$KEY=.*|\\\$KEY=\\\"\$ESCAPED_SECRET\\\"|\" \"\\\$ENV_FILE\"
    else
      echo \"\\\$KEY=\\\"\$ESCAPED_SECRET\\\"\" >> \"\\\$ENV_FILE\"
    fi

    systemctl restart apache2 || true
  '"
        done
