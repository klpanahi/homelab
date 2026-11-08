#!/usr/bin/env bash
# First-time setup of OpenBao (docs/openbao.md). Run this yourself in a terminal
# that no agent is reading: it shows the unseal key and root token once.
#
# Creates one unseal key (no splitting: there is one operator), the KV store at
# secret/, an admin policy and a userpass login, then revokes the root token.
set -euo pipefail

export BAO_ADDR="${BAO_ADDR:-https://openbao.panahi-systems.com}"

if bao status -format=json | jq -e '.initialized' >/dev/null; then
  echo "OpenBao at $BAO_ADDR is already initialized. Nothing to do." >&2
  exit 1
fi

init="$(bao operator init -key-shares=1 -key-threshold=1 -format=json)"
unseal_key="$(jq -r '.unseal_keys_b64[0]' <<<"$init")"
BAO_TOKEN="$(jq -r '.root_token' <<<"$init")"
export BAO_TOKEN
unset init

printf '\nUnseal key (shown once):\n\n  %s\n\n' "$unseal_key"
echo "Save it outside the homelab, in a password manager or on paper."
echo "Without it, nothing stored in OpenBao can ever be read again."
# Loops rather than exits: the key and root token exist only in this run.
answer=""
until [ "$answer" = "SAVED" ]; do
  read -r -p "Type SAVED when you have it: " answer
done
clear

# Over stdin, so the key isn't in the process list.
jq -n --arg key "$unseal_key" '{key: $key}' | bao write sys/unseal - >/dev/null
unset unseal_key

bao secrets enable -path=secret -version=2 kv >/dev/null

bao policy write homelab-admin - >/dev/null <<'POLICY'
path "secret/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}
POLICY

bao auth enable userpass >/dev/null

username=""
until [ -n "$username" ]; do
  read -r -p "Login name: " username
done
while :; do
  read -r -s -p "Password: " password; echo
  read -r -s -p "Password again: " password2; echo
  [ -n "$password" ] && [ "$password" = "$password2" ] && break
  echo "Passwords are empty or differ. Try again."
done

# Over stdin, so the password isn't in the process list.
jq -n --arg p "$password" '{password: $p, token_policies: "homelab-admin", token_ttl: "8h", token_max_ttl: "24h"}' \
  | bao write "auth/userpass/users/$username" - >/dev/null

# The unseal key can mint a new root token (bao operator generate-root).
bao token revoke -self >/dev/null
unset BAO_TOKEN

# Log in now, so Terraform and Ansible work straight away.
token="$(jq -n --arg p "$password" '{password: $p}' | bao write -field=token "auth/userpass/login/$username" -)"
unset password password2
(umask 077; printf '%s' "$token" > "$HOME/.vault-token")
unset token

echo
echo "Done. You are logged in as $username for 8 hours."
echo "Log in again later with:"
echo "  BAO_ADDR=$BAO_ADDR bao login -method=userpass username=$username"
echo "Web UI: $BAO_ADDR/ui"
