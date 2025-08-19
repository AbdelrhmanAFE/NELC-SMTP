  gcloud secrets versions access latest --secret=nelc-email-password > /workspace/secret.txt
        SECRET=$(cat /workspace/secret.txt)


        declare -A DRUPAL_VMS_ZONES=(
          ["nelc-app-deployment"]="me-central2-b"
        )
        declare -A DRUPAL_SETTINGS_PATHS=(
          ["nelc-app-deployment"]="/var/www/nelc/web/sites/default/settings.local.php"
        )

        for vm in "${!DRUPAL_VMS_ZONES[@]}"; do
          zone="${DRUPAL_VMS_ZONES[$vm]}"
          settings_file="${DRUPAL_SETTINGS_PATHS[$vm]:-/var/www/nelc/web/sites/default/settings.local.php}"
          echo "🔧 Updating Drupal on $vm ($zone)... Settings file: $settings_file"

          ESCAPED_SECRET=$(printf "%s" "$SECRET" | sed "s/[\/&]/\\\\&/g")

          gcloud compute ssh "$vm" \
            --zone="$zone" \
            --project="nelc-futurex-prod" \
            --tunnel-through-iap \
            --command="bash -c 'KEY=\\\"\$config['smtp.settings']['smtp_password']\\\"; \
              SETTINGS_FILE=\"$settings_file\"; \
              ESCAPED_SECRET=\"$ESCAPED_SECRET\"; \
              if grep -q \"\$KEY\" \"\$SETTINGS_FILE\"; then \
                sed -i \"s|\$KEY = .*|\$KEY = '\$ESCAPED_SECRET';|\" \"\$SETTINGS_FILE\"; \
              else \
                echo \"\$KEY = '\$ESCAPED_SECRET';\" >> \"\$SETTINGS_FILE\"; \
              fi; \
              command -v drush &>/dev/null && /var/www/nelc/vendor/bin/drush cr || true'"
        done
