Set-StrictMode -Version Latest

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-SecretVaultPassphrase {
    param(
        [string]$Passphrase,
        [string]$EnvironmentName = "MONITORING_SECRET_VAULT_PASSPHRASE"
    )

    if (-not [string]::IsNullOrWhiteSpace($Passphrase)) {
        return $Passphrase
    }

    $envValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue.Trim()
    }

    throw "Set -Passphrase or define $EnvironmentName."
}

function New-RandomBytes {
    param([int]$Length)

    $buffer = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
    }
    finally {
        $rng.Dispose()
    }

    return $buffer
}

function Join-ByteArrays {
    param([byte[][]]$Arrays)

    $stream = New-Object System.IO.MemoryStream
    try {
        foreach ($array in $Arrays) {
            if ($null -eq $array -or $array.Length -eq 0) {
                continue
            }
            $stream.Write($array, 0, $array.Length)
        }

        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Test-ByteArrayEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }

    $difference = 0
    for ($i = 0; $i -lt $Left.Length; $i++) {
        $difference = $difference -bor ($Left[$i] -bxor $Right[$i])
    }

    return $difference -eq 0
}

function Get-SecretVaultKeyMaterial {
    param(
        [string]$Passphrase,
        [byte[]]$Salt,
        [int]$Iterations = 200000
    )

    $deriveBytes = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Passphrase,
        $Salt,
        $Iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )

    try {
        return @{
            EncryptionKey = $deriveBytes.GetBytes(32)
            MacKey = $deriveBytes.GetBytes(32)
            Iterations = $Iterations
        }
    }
    finally {
        $deriveBytes.Dispose()
    }
}

function Protect-SecretVaultPayload {
    param(
        [string]$Plaintext,
        [string]$Passphrase
    )

    $format = "monitoring-secret-vault/v1"
    $salt = New-RandomBytes -Length 16
    $iv = New-RandomBytes -Length 16
    $keyMaterial = Get-SecretVaultKeyMaterial -Passphrase $Passphrase -Salt $salt
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Plaintext)

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keyMaterial.EncryptionKey
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $encryptor = $aes.CreateEncryptor()
        try {
            $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
        }
        finally {
            $encryptor.Dispose()
        }
    }
    finally {
        $aes.Dispose()
    }

    $macInput = Join-ByteArrays -Arrays @(
        [System.Text.Encoding]::UTF8.GetBytes($format),
        $salt,
        $iv,
        $cipherBytes
    )
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyMaterial.MacKey)
    try {
        $macBytes = $hmac.ComputeHash($macInput)
    }
    finally {
        $hmac.Dispose()
    }

    return [ordered]@{
        format = $format
        cipher = "AES-256-CBC"
        kdf = "PBKDF2-SHA256"
        iterations = $keyMaterial.Iterations
        salt = [Convert]::ToBase64String($salt)
        iv = [Convert]::ToBase64String($iv)
        mac = [Convert]::ToBase64String($macBytes)
        ciphertext = [Convert]::ToBase64String($cipherBytes)
    }
}

function Unprotect-SecretVaultPayload {
    param(
        [psobject]$VaultRecord,
        [string]$Passphrase
    )

    if ($VaultRecord.format -ne "monitoring-secret-vault/v1") {
        throw "Unsupported vault format '$($VaultRecord.format)'."
    }

    $salt = [Convert]::FromBase64String([string]$VaultRecord.salt)
    $iv = [Convert]::FromBase64String([string]$VaultRecord.iv)
    $cipherBytes = [Convert]::FromBase64String([string]$VaultRecord.ciphertext)
    $expectedMac = [Convert]::FromBase64String([string]$VaultRecord.mac)
    $iterations = [int]$VaultRecord.iterations
    $keyMaterial = Get-SecretVaultKeyMaterial -Passphrase $Passphrase -Salt $salt -Iterations $iterations

    $macInput = Join-ByteArrays -Arrays @(
        [System.Text.Encoding]::UTF8.GetBytes([string]$VaultRecord.format),
        $salt,
        $iv,
        $cipherBytes
    )
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyMaterial.MacKey)
    try {
        $actualMac = $hmac.ComputeHash($macInput)
    }
    finally {
        $hmac.Dispose()
    }

    if (-not (Test-ByteArrayEqual -Left $expectedMac -Right $actualMac)) {
        throw "Vault MAC verification failed. The passphrase is wrong or the vault file was modified."
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keyMaterial.EncryptionKey
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $decryptor = $aes.CreateDecryptor()
        try {
            $plainBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
        }
        finally {
            $decryptor.Dispose()
        }
    }
    finally {
        $aes.Dispose()
    }

    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}
