#!/bin/bash

# The secrets file is the source of truth for the "username -> secret" mapping.
# mtg.toml is derived from it, and index.php reads it to show a user its own key.
secrets_file="$install_dir/conf/secrets.toml"
config_file="$install_dir/conf/mtg.toml"

mtg_generate_secret() {
    "$install_dir/mtg-multi" generate-secret --hex "$frontend_domain" | tr -d '[:space:]'
}

mtg_secret_of() {
    local user="$1"
    [ -s "$secrets_file" ] || return 1
    grep -oP "^\"\Q$user\E\" = \"\K[0-9a-fA-F]+" "$secrets_file" | head -n1
}

# Create a secret for every YunoHost user that doesn't have one yet, and drop
# the entries of users that no longer exist.
mtg_sync_secrets() {
    local tmp user secret
    tmp="$(mktemp "$install_dir/conf/.secrets.toml.XXXXXX")"

    for user in $(ynh_user_list); do
        secret="$(mtg_secret_of "$user" || true)"
        [ -n "$secret" ] || secret="$(mtg_generate_secret)"
        echo "\"$user\" = \"$secret\"" >>"$tmp"
    done

    chown "$app:$app" "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$secrets_file"
}

mtg_web_enabled() {
    [ "${web:-0}" = "1" ] && [ -n "${web_domain:-}" ]
}

mtg_validate_web() {
    [ "${web:-0}" = "1" ] || return 0
    if [ -z "${web_domain:-}" ]; then
        ynh_die "A domain (web_domain) is required when WEB proxy mode is enabled."
    fi
    if [ "$web_domain" = "$domain" ] && [ "$path" = "/" ]; then
        ynh_die "WEB proxy mode cannot share the root '/' of $domain with the status page. Install the status page on a sub-path (e.g. /mtg-multi) or choose a dedicated WEB domain."
    fi
}

# Rewrite the [secrets] table of mtg.toml atomically from the secrets file so a
# concurrent SIGHUP reload never observes a truncated configuration.
# [secrets] is the last section of the template, so truncating right after its
# header and re-appending the entries is enough.
mtg_apply_secrets() {
    local tmp
    tmp="$(mktemp "$install_dir/conf/.mtg.toml.XXXXXX")"
    sed '/^\[secrets\]$/q' "$config_file" >"$tmp"
    cat "$secrets_file" >>"$tmp"
    chown "$app:$app" "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$config_file"
    ynh_store_file_checksum "$config_file"
}

mtg_add_config() {
    local prom_enabled web_bind_to web_host
    [ "${prometheus:-0}" = "1" ] && prom_enabled="true" || prom_enabled="false"
    if mtg_web_enabled; then
        web_bind_to="127.0.0.1:$port_web"
        web_host="$web_domain"
    else
        web_bind_to=""
        web_host=""
    fi
    ynh_config_add --template="mtg.toml" --destination="$config_file"
    mtg_apply_secrets
}

mtg_add_index_php() {
    local web_enabled web_domain="${web_domain:-}"
    mtg_web_enabled && web_enabled="true" || web_enabled="false"
    ynh_config_add --template="index.php" --destination="$install_dir/www/index.php"
    chown "$app:$app" "$install_dir/www/index.php"
}

mtg_setup_web_permission() {
    if mtg_web_enabled; then
        ynh_permission_url --permission="web" --url="$web_domain/" --auth_header=false
    else
        ynh_permission_url --permission="web" --clear_urls
    fi
}

mtg_remove_web_nginx() {
    local conf_file removed=0
    for conf_file in /etc/nginx/conf.d/*.d/"$app-web.conf"; do
        [ -e "$conf_file" ] || continue
        ynh_delete_file_checksum "$conf_file"
        ynh_safe_rm "$conf_file"
        removed=1
    done
    if [ "$removed" = "1" ]; then
        ynh_systemctl --service=nginx --action=reload
    fi
}

mtg_setup_web_nginx() {
    mtg_remove_web_nginx
    if mtg_web_enabled; then
        local web_nginx_conf="/etc/nginx/conf.d/$web_domain.d/$app-web.conf"
        ynh_config_add --template="nginx-web.conf" --destination="$web_nginx_conf"
        ynh_systemctl --service=nginx --action=reload
    fi
}

# index.php runs as $app and may therefore rewrite the secret files, but not
# reload the service. A systemd path unit watching a trigger file does it.
mtg_add_reload_units() {
    touch "$install_dir/conf/.reload"
    chown "$app:$app" "$install_dir/conf/.reload"
    chmod 600 "$install_dir/conf/.reload"

    ynh_config_add --template="reload.service" --destination="/etc/systemd/system/$app-reload.service"
    ynh_config_add --template="reload.path" --destination="/etc/systemd/system/$app-reload.path"
    systemctl daemon-reload
    systemctl enable --now "$app-reload.path" --quiet
}

mtg_remove_reload_units() {
    systemctl disable --now "$app-reload.path" --quiet 2>/dev/null || true
    ynh_safe_rm "/etc/systemd/system/$app-reload.path"
    ynh_safe_rm "/etc/systemd/system/$app-reload.service"
    systemctl daemon-reload
}

# The post_user_create / post_user_delete hooks live in the package's hooks/
# folder: YunoHost installs them into /etc/yunohost/hooks.d/ itself on install,
# upgrade and restore, and removes them on uninstall. Doing it from the scripts
# would be pointless, as core runs hook_remove(app) after the install script.
