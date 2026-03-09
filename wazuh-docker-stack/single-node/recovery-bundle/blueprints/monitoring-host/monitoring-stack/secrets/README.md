# Secrets

This directory is intentionally excluded from Git.

Store local-only runtime secrets here, for example:

- `brevo_smtp_key.txt`
- `gateway_admin_username.txt`
- `gateway_admin_password.txt`
- `gateway_admin_password_hash.txt`
- `vm_ssh_password.txt`
- `vm_sudo_password.txt`
- `pihole_web_password.txt`

Do not commit real credentials.

For an encrypted local backup of these files, use:

- `scripts/windows/Invoke-SecretVaultExport.ps1`
- `scripts/windows/Invoke-SecretVaultImport.ps1`
- `scripts/windows/Invoke-SecretVaultRekey.ps1`
