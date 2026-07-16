$repoRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $repoRoot 'claude-codex-battery-win.ps1'
. $mainScript

Describe 'Claude authentication diagnostics' {
  BeforeEach {
    $script:CRED_FILE = Join-Path $TestDrive '.credentials.json'
  }

  It 'distinguishes a missing credential file' {
    $result = Read-ClaudeOAuthCredential
    $result.ok | Should Be $false
    $result.failure.kind | Should Be 'credentialMissing'
  }

  It 'distinguishes malformed credential JSON' {
    Set-Content -LiteralPath $script:CRED_FILE -Value '{broken' -Encoding UTF8
    $result = Read-ClaudeOAuthCredential
    $result.ok | Should Be $false
    $result.failure.kind | Should Be 'credentialInvalid'
  }

  It 'distinguishes an expired access token' {
    $expired = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeMilliseconds()
    @{ claudeAiOauth = @{ accessToken='test-token'; refreshToken='test-refresh'; expiresAt=$expired } } |
      ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:CRED_FILE -Encoding UTF8
    $result = Read-ClaudeOAuthCredential
    $result.ok | Should Be $false
    $result.failure.kind | Should Be 'tokenExpired'
    $result.refreshTokenPresent | Should Be $true
  }

  It 'accepts a readable unexpired OAuth credential' {
    $future = [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeMilliseconds()
    @{ claudeAiOauth = @{ accessToken='test-token'; refreshToken='test-refresh'; expiresAt=$future } } |
      ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:CRED_FILE -Encoding UTF8
    $result = Read-ClaudeOAuthCredential
    $result.ok | Should Be $true
    $result.failure | Should Be $null
  }

  It 're-reads credentials and retries exactly once after HTTP 401' {
    Mock Read-ClaudeOAuthCredential {
      [pscustomobject]@{ ok=$true; token='test-token'; expiresAt=0; refreshTokenPresent=$true; stamp=10; failure=$null }
    }
    $script:usageRequestCount = 0
    Mock Invoke-UsageApiOnce {
      $script:usageRequestCount++
      if ($script:usageRequestCount -eq 1) {
        return [pscustomobject]@{ ok=$false; raw=$null; failure=(New-ClaudeFailure 'http401' 401 10 'Unauthorized') }
      }
      return [pscustomobject]@{ ok=$true; raw=[pscustomobject]@{ five_hour=$null; seven_day=$null; limits=@() }; failure=$null }
    }
    Mock Write-CcbLog {}

    $result = Invoke-UsageApi
    $result.ok | Should Be $true
    $script:usageRequestCount | Should Be 2
  }
}

Describe 'Claude usage recovery' {
  It 'bypasses an active auth backoff when the credential file changes' {
    $now = Get-UnixNow
    Mock Read-UsageCache {
      [pscustomobject]@{
        fetchedAt=$null; raw=$null; backoffUntil=($now + 3600); backoffInterval=3600
        failure=[pscustomobject]@{ kind='http401'; statusCode=401; credentialStamp=10; failedAt=$now; retryAt=($now + 3600) }
      }
    }
    Mock Get-ClaudeCredentialStamp { [int64]20 }
    Mock Invoke-UsageApi {
      [pscustomobject]@{
        ok=$true
        raw=[pscustomobject]@{
          five_hour=[pscustomobject]@{ utilization=12; resets_at=$null }
          seven_day=[pscustomobject]@{ utilization=34; resets_at=$null }
          limits=@()
        }
        failure=$null
      }
    }
    Mock Write-UsageCache {}
    Mock Write-CcbLog {}

    $result = Get-ClaudeUsage
    Assert-MockCalled Invoke-UsageApi -Times 1 -Exactly
    $result.fiveHour.pct | Should Be 12
    $result.weekly.pct | Should Be 34
  }
}

Describe 'Release identity' {
  It 'keeps VERSION and the script version in sync' {
    $versionFile = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
    $versionFile | Should Be $script:VERSION
    $versionFile | Should Be '1.1.3-win'
  }
}
