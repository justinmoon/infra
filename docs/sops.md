# SOPS Secrets

This repo stores secrets in `secrets/*.yaml` encrypted with `sops` + `age`.

## Recipients

Recipients (public) live in two places:

- Canonical: `.sops.yaml` (used by sops when encrypting)
- Reference: `sops/recipients.txt`

Do not commit any age identities, private keys, or YubiKey identity tokens (e.g. `AGE-PLUGIN-YUBIKEY-...`).

## Local Editing (YubiKey)

If you have the YubiKeys plugged in, point sops at your YubiKey identities file and run inside the devshell:

```bash
cd ~/code/infra
SOPS_AGE_KEY_FILE=~/configs/yubikeys/keys.txt nix develop -c sops secrets/openclaw.yaml
```

## Server Decryption (streambot)

`streambot` decrypts secrets at activation time using a one-off age key stored at:

- `/etc/age/key.txt`

NixOS config uses:

- `sops.age.keyFile = "/etc/age/key.txt";`

You can sanity-check decryption on the host:

```bash
SOPS_AGE_KEY_FILE=/etc/age/key.txt sops -d /path/to/secrets/openclaw.yaml
```

## Rotating Keys

- Changing recipients: update `.sops.yaml`, then re-encrypt affected files (avoid `sops set` pipelines).
- Changing a secret value: edit with `sops <file>` and save.
