# Read-only authentication metadata for the organization ownership migration.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('OpenAI', 'OpenRouter', 'GitHubToken')][string]$Provider,
    [Parameter(Mandatory)][long]$ExpectedRepositoryId,
    [Parameter(Mandatory)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:failureCategory = 'precondition'

function Invoke-CredentialMetadataGet {
    param([string]$Uri, [string]$Token)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $request.Headers.UserAgent.ParseAdd('HemSoft-Migration-Credential-Check')
    $response = $null
    try {
        $script:failureCategory = 'provider_unavailable'
        $response = $client.Send($request)
        if ([int]$response.StatusCode -ne 200) {
            $script:failureCategory = switch ([int]$response.StatusCode) {
                401 { 'authentication_rejected' }; 403 { 'authentication_or_policy_rejected' }
                429 { 'rate_limited' }; default { 'provider_http_error' }
            }
            throw 'Credential metadata GET failed.'
        }
        $script:failureCategory = 'invalid_response'
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        $scopes = if ($response.Headers.Contains('X-OAuth-Scopes')) {
            ($response.Headers.GetValues('X-OAuth-Scopes') -join ',').Split(',').Trim()
        } else { @() }
        return @{ data = $body; scopes = $scopes }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
}

try {
    if ($env:GITHUB_ACTOR -cne 'HemSoft' -or $env:GITHUB_TRIGGERING_ACTOR -cne 'HemSoft' -or
        $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
        [long]$env:GITHUB_REPOSITORY_ID -ne $ExpectedRepositoryId -or
        $env:GITHUB_REPOSITORY_OWNER -cnotin @('HemSoft', 'hemsoft-dev') -or
        [string]::IsNullOrWhiteSpace($env:VERIFY_CREDENTIAL_TOKEN)) {
        throw 'Trusted main credential check prerequisites are missing.'
    }
    $script:failureCategory = 'provider_response'
    $result = [ordered]@{
        repository_id = $ExpectedRepositoryId
        repository = $env:GITHUB_REPOSITORY
        reviewed_sha = $env:GITHUB_SHA
        run_url = "https://github.com/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
        provider = $Provider
        method = 'GET'
        authentication = 'verified'
        # Authentication metadata does not prove model or deployment runtime.
        runtime_verified = $false
    }
    switch ($Provider) {
        'OpenAI' {
            $proof = Invoke-CredentialMetadataGet 'https://api.openai.com/v1/models' $env:VERIFY_CREDENTIAL_TOKEN
            if ($proof.data.object -cne 'list' -or $proof.data.data -isnot [array]) {
                throw 'Unexpected model-list response.'
            }
        }
        'OpenRouter' {
            $proof = Invoke-CredentialMetadataGet 'https://openrouter.ai/api/v1/key' $env:VERIFY_CREDENTIAL_TOKEN
            if ($proof.data.data -isnot [System.Collections.IDictionary]) { throw 'Unexpected current-key response.' }
            $expires = $proof.data.data['expires_at']
            if ($null -ne $expires -and [DateTimeOffset]::Parse($expires) -le [DateTimeOffset]::UtcNow) {
                $script:failureCategory = 'credential_expired'
                throw 'Provider credential has expired.'
            }
        }
        'GitHubToken' {
            $actor = Invoke-CredentialMetadataGet 'https://api.github.com/user' $env:VERIFY_CREDENTIAL_TOKEN
            $script:failureCategory = 'identity_or_access'
            if ($actor.data.login -cne 'HemSoft') { throw 'Unexpected credential actor.' }
            $repository = Invoke-CredentialMetadataGet "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)" $env:VERIFY_CREDENTIAL_TOKEN
            $script:failureCategory = 'identity_or_access'
            if ($repository.data.id -ne $ExpectedRepositoryId -or $repository.data.full_name -cne $env:GITHUB_REPOSITORY -or
                $repository.data.permissions.push -ne $true -or
                ($actor.scopes.Count -gt 0 -and ($actor.scopes -notcontains 'repo') -and
                 (($actor.scopes -notcontains 'public_repo') -or $repository.data.private -eq $true))) {
                throw 'Current repository write permission or repository scope is missing.'
            }
            $result.actor = 'HemSoft'
            $result.repository_scope = if ($actor.scopes -contains 'repo') { 'repo' } elseif ($actor.scopes -contains 'public_repo') { 'public_repo' } else { 'unreported' }
            # Repository metadata reports the actor's permission, not fine-grained token write grants.
            $result.repository_access = 'metadata'
            $result.actor_repository_access = 'write'
            $result.token_write_permissions_verified = $false
            $result.post_transfer_access_verified = $env:GITHUB_REPOSITORY_OWNER -ceq 'hemsoft-dev'
        }
    }
    $script:failureCategory = 'metadata_output'
    $result.observed_at = [DateTimeOffset]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $OutputPath -Encoding utf8
} catch {
    throw "Read-only credential authentication failed ($script:failureCategory). No credential or provider response is reported."
} finally {
    Remove-Item Env:VERIFY_CREDENTIAL_TOKEN -ErrorAction SilentlyContinue
}
