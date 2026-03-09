# Secret Vault

This runbook keeps local secrets in one encrypted export instead of leaving your only backup as plaintext files under `secrets/` and local `.env` files.

## Scope

The vault workflow covers these local-only files when they exist:

- `.env`
- `wazuh-docker-stack/.env`
- files under `secrets/` used by the monitoring host and sensor bootstrap
- Wazuh password files under `wazuh-docker-stack/secrets/`
- `local/operator-private/credentials.override.json`

The encrypted vault file is written to:

- `local/secret-vault/monitoring-secrets.enc.json`

This path is gitignored.

## Export

Set a passphrase and export the current local secret state:

```powershell
$env:MONITORING_SECRET_VAULT_PASSPHRASE = "choose-a-strong-passphrase"
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-SecretVaultExport.ps1
```

You can also pass the passphrase directly with `-Passphrase`.

## Import

Restore the encrypted secret bundle back into the repo workspace:

```powershell
$env:MONITORING_SECRET_VAULT_PASSPHRASE = "choose-a-strong-passphrase"
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-SecretVaultImport.ps1
```

If a destination file already exists, the import creates a backup under:

- `local/secret-vault/import-backup/<timestamp>/`

## Rekey

Rotate the vault passphrase without rewriting the plaintext files manually:

```powershell
$env:MONITORING_SECRET_VAULT_PASSPHRASE = "current-passphrase"
$env:MONITORING_SECRET_VAULT_NEW_PASSPHRASE = "new-passphrase"
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-SecretVaultRekey.ps1
```

The previous encrypted file is preserved as a timestamped `.bak`.

## Rotation Guidance

Use the vault together with the existing runtime secret rotation helpers:

- gateway access: `scripts/windows/Invoke-GatewayAccessSetup.ps1 -RotatePassword`
- migrated plaintext cleanup: `scripts/windows/Invoke-ProjectSecretMigration.ps1`
- Wazuh runtime config rendering: `scripts/windows/Invoke-WazuhSingleNodeCompose.ps1`

After rotating a runtime secret, export the vault again so the encrypted backup stays current.

## Recovery Drill Use

The bare-metal rebuild rehearsal imports this vault into a staged clean workspace before running the Wazuh and monitoring rollout validators:

```powershell
$env:MONITORING_SECRET_VAULT_PASSPHRASE = "choose-a-strong-passphrase"
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-BareMetalRebuildDrill.ps1
```
