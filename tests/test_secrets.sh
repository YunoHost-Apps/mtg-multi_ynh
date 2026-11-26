#!/bin/bash
# Offline harness for the packaging logic (no YunoHost needed).
# Fakes the mtg-multi binary + the ynh_* helpers used by _common.sh, then
# exercises secret sync, config rendering and the user hooks.

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

app="mtg-multi"
install_dir="$work/install"
domain="proxy.example.tld"
path="/mtg-multi"
frontend_domain="storage.googleapis.com"
port=3128
port_api=9090
port_prometheus=3129
port_web=18080
dns="1.1.1.1"
prometheus=0
web=0
web_domain=""
users=(alice bob)

mkdir -p "$install_dir/conf" "$install_dir/www"

cat >"$install_dir/mtg-multi" <<'EOF'
#!/bin/bash
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
echo
EOF
chmod +x "$install_dir/mtg-multi"

# --- helper stubs -------------------------------------------------------
ynh_user_list() { printf '%s\n' "${users[@]}"; }
ynh_store_file_checksum() { :; }
ynh_die() { echo "YNH_DIE: $*" >&2; return 1; }
ynh_config_add() {
    local template destination
    while [ $# -gt 0 ]; do
        case "$1" in
            --template=*) template="${1#*=}" ;;
            --destination=*) destination="${1#*=}" ;;
        esac
        shift
    done
    local content
    content="$(cat "$repo/conf/$template")"
    for var in APP INSTALL_DIR DOMAIN PATH PORT PORT_API PORT_PROMETHEUS PORT_WEB DNS PROM_ENABLED FRONTEND_DOMAIN WEB_BIND_TO WEB_HOST WEB_ENABLED WEB_DOMAIN; do
        local lower="${var,,}"
        content="${content//__${var}__/${!lower-}}"
    done
    printf '%s\n' "$content" >"$destination"
}
chown() { :; }

# `install -o app -g app` would fail with a non-existent user
install() {
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -o | -g)
                shift 2
                continue
                ;;
        esac
        args+=("$1")
        shift
    done
    command install "${args[@]}"
}

source "$repo/scripts/_common.sh"

# --- 1. initial sync ----------------------------------------------------
mtg_sync_secrets
mtg_add_config

echo "--- mtg.toml ---"
cat "$config_file"

alice_secret="$(mtg_secret_of alice)"
bob_secret="$(mtg_secret_of bob)"
[ -n "$alice_secret" ] && [ -n "$bob_secret" ] || { echo "FAIL: missing secrets"; exit 1; }
[ "$alice_secret" != "$bob_secret" ] || { echo "FAIL: secrets are not unique"; exit 1; }
python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert sorted(d['secrets'])==['alice','bob'], d['secrets']" "$config_file"
echo "PASS: initial sync produces valid TOML with one unique secret per user"

# --- 2. idempotency -----------------------------------------------------
mtg_sync_secrets
mtg_add_config
[ "$(mtg_secret_of alice)" = "$alice_secret" ] || { echo "FAIL: secret not preserved"; exit 1; }
echo "PASS: re-sync preserves existing secrets"

# --- 3. post_user_create hook ------------------------------------------
# The real hooks read the app settings back from settings.yml, so fake one and
# point the rendered copies at it.
cat >"$work/settings.yml" <<EOF
app: $app
frontend_domain: $frontend_domain
install_dir: $install_dir
EOF

render_hook() {
    grep -q '^systemctl reload-or-restart ' "$repo/hooks/$1" \
        || { echo "FAIL: $1 does not use reload-or-restart"; exit 1; }
    sed -e "s|^settings=.*|settings=\"$work/settings.yml\"|" \
        -e "s|^systemctl reload-or-restart .*|true|" -e "s|^chown |true |" \
        "$repo/hooks/$1" >"$work/$1"
    chmod +x "$work/$1"
}
render_hook post_user_create
render_hook post_user_delete

"$work/post_user_create" carol
python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert sorted(d['secrets'])==['alice','bob','carol'], d['secrets']" "$config_file"
[ "$(mtg_secret_of alice)" = "$alice_secret" ] || { echo "FAIL: hook clobbered alice"; exit 1; }
echo "PASS: post_user_create adds a secret without touching the others"

"$work/post_user_create" carol
python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert sorted(d['secrets'])==['alice','bob','carol'], d['secrets']" "$config_file"
echo "PASS: post_user_create is idempotent"

# --- 4. post_user_delete hook ------------------------------------------
"$work/post_user_delete" bob
python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert sorted(d['secrets'])==['alice','carol'], d['secrets']" "$config_file"
echo "PASS: post_user_delete revokes only that user's secret"

# --- 5. rejects junk usernames -----------------------------------------
"$work/post_user_create" 'evil"] = "x' || true
python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert sorted(d['secrets'])==['alice','carol'], d['secrets']" "$config_file"
echo "PASS: malformed usernames are ignored"

# --- 6. no leftover temp files & mode 600 ------------------------------
leftovers="$(find "$install_dir/conf" -maxdepth 1 -name '.*' ! -name '.reload')"
[ -z "$leftovers" ] || { echo "FAIL: leftover temp files: $leftovers"; exit 1; }
[ "$(stat -c %a "$secrets_file")" = "600" ] && [ "$(stat -c %a "$config_file")" = "600" ] \
    || { echo "FAIL: secret/config files are not 0600"; exit 1; }
echo "PASS: atomic writes leave no temp files and keep mode 0600"

# --- 7. WEB mode config & conflict guard -------------------------------
python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert d['web']['bind-to']=='', d['web']" "$config_file"
echo "PASS: WEB mode is disabled in mtg.toml by default"

web=1
web_domain="webproxy.example.tld"
mtg_validate_web
mtg_add_config
python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); assert d['web']['bind-to']=='127.0.0.1:18080', d['web']; assert d['web']['host']=='webproxy.example.tld', d['web']; assert sorted(d['secrets'])==['alice','carol'], d['secrets']" "$config_file"
echo "PASS: enabling WEB mode populates [web] and preserves [secrets] at the end"

web_domain="$domain"
path="/"
if (mtg_validate_web) 2>/dev/null; then
    echo "FAIL: mtg_validate_web allowed sharing '/' with status page"
    exit 1
fi
echo "PASS: mtg_validate_web rejects root-path collision on the same domain"

# --- 8. install / upgrade / restore WEB lifecycle symmetry -------------
for script in install upgrade restore; do
    for helper in mtg_setup_web_permission mtg_setup_web_nginx; do
        grep -qx "$helper" "$repo/scripts/$script" \
            || { echo "FAIL: scripts/$script missing $helper"; exit 1; }
    done
done
echo "PASS: install, upgrade and restore configure WEB permission and nginx symmetrically"

# --- 9. manifest port pattern & hardened reload.service ----------------
python3 - "$repo/manifest.toml" <<'PY'
import re, sys, tomllib
m = tomllib.load(open(sys.argv[1], "rb"))
p = m["install"]["port"]
assert "min" not in p and "max" not in p, p
rx = re.compile(p["pattern"]["regexp"])
for ok_port in ("1024", "3128", "8443", "65535"):
    assert rx.match(ok_port), ok_port
for bad_port in ("0", "80", "1023", "65536", "70000", "abc"):
    assert not rx.match(bad_port), bad_port
PY
echo "PASS: manifest [install.port] enforces 1024..65535 via schema-valid pattern"

ynh_config_add --template="reload.service" --destination="$work/mtg-multi-reload.service"
grep -qx "User=mtg-multi" "$work/mtg-multi-reload.service" \
    || { echo "FAIL: reload.service missing User=mtg-multi"; exit 1; }
grep -qx "Group=mtg-multi" "$work/mtg-multi-reload.service" \
    || { echo "FAIL: reload.service missing Group=mtg-multi"; exit 1; }
for directive in PrivateTmp ProtectSystem SystemCallFilter CapabilityBoundingSet; do
    grep -q "^${directive}=" "$work/mtg-multi-reload.service" \
        || { echo "FAIL: reload.service missing ${directive}="; exit 1; }
done
echo "PASS: reload.service runs as mtg-multi with systemd security hardening"

echo
echo "All packaging-logic tests passed."
