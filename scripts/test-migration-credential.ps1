Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$paths=@((Join-Path $PSScriptRoot 'verify-migration-credential.ps1'))
$content=Get-Content -Raw -LiteralPath $paths[0]
foreach($path in $paths){if((Get-Content -Raw -LiteralPath $path) -cne $content){throw 'Credential helper copies differ.'}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($content,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'PowerShell parse failed.'}
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-CredentialMetadataGet'},$false)
$mock=@'
function Invoke-CredentialMetadataGet {
 param([string]$Uri,[string]$Token)
 if($Token -cne 'synthetic-private-token'){throw 'Unexpected credential supplied.'}
 $global:FixtureCalls.Add($Uri)
 if($global:FixtureRejected){throw 'Synthetic provider rejection.'}
 switch($Uri){
  'https://api.openai.com/v1/models' { return @{data=@{object=$global:FixtureList;data=@()};scopes=@()} }
  'https://openrouter.ai/api/v1/key' {return @{data=@{data=@{expires_at=$global:FixtureExpiry}};scopes=@()} }
  'https://api.github.com/user' {return @{data=@{login=$global:FixtureActor};scopes=$global:FixtureScopes} }
  'https://api.github.com/repos/HemSoft/dashboard' {return @{data=@{id=$global:FixtureRepoId;full_name='HemSoft/dashboard';private=$true;permissions=@{push=$global:FixturePush}};scopes=@()} }
  default {throw 'Unexpected URL.'}
 }
}
'@
$body=$content.Substring($ast.ParamBlock.Extent.EndOffset)
$relativeStart=$function.Extent.StartOffset-$ast.ParamBlock.Extent.EndOffset
$relativeEnd=$function.Extent.EndOffset-$ast.ParamBlock.Extent.EndOffset
$body=$body.Substring(0,$relativeStart)+$mock+$body.Substring($relativeEnd)
$script=[ScriptBlock]::Create($body)
$directory=Join-Path ([IO.Path]::GetTempPath()) ('sfl-health-fixtures-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$results=[Collections.Generic.List[object]]::new()
try {
 foreach($case in @('openai-valid','openrouter-valid','pat-valid','openai-bad-list','openrouter-expired','pat-wrong-actor',
  'pat-wrong-repository','pat-no-push','pat-public-only','provider-rejected','wrong-ref','wrong-event','wrong-owner','wrong-actor','wrong-rerun-actor','missing-key')){
  $global:FixtureCalls=[Collections.Generic.List[string]]::new();$global:FixtureList='list';$global:FixtureExpiry=$null
  $global:FixtureActor='HemSoft';$global:FixtureScopes=@('repo');$global:FixtureRepoId=1120402599;$global:FixturePush=$true;$global:FixtureRejected=$false
  $Provider=if($case.StartsWith('openai')){'OpenAI'}elseif($case.StartsWith('openrouter')){'OpenRouter'}else{'GitHubToken'}
  $ExpectedRepositoryId=1120402599;$OutputPath=Join-Path $directory ($case+'.json')
  $env:GITHUB_EVENT_NAME='workflow_dispatch';$env:GITHUB_REF='refs/heads/main';$env:GITHUB_REPOSITORY_ID='1120402599'
  $env:GITHUB_REPOSITORY_OWNER='HemSoft';$env:GITHUB_REPOSITORY='HemSoft/dashboard';$env:GITHUB_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  $env:GITHUB_RUN_ID='1';$env:GITHUB_ACTOR='HemSoft';$env:GITHUB_TRIGGERING_ACTOR='HemSoft';$env:VERIFY_CREDENTIAL_TOKEN='synthetic-private-token'
  switch($case){
   'openai-bad-list' {$global:FixtureList='other'}
   'openrouter-expired' {$global:FixtureExpiry='2020-01-01T00:00:00Z'}
   'pat-wrong-actor' {$global:FixtureActor='other'}
   'pat-wrong-repository' {$global:FixtureRepoId=1}
   'pat-no-push' {$global:FixturePush=$false}
   'pat-public-only' {$global:FixtureScopes=@('public_repo')}
   'provider-rejected' {$global:FixtureRejected=$true}
   'wrong-ref' {$env:GITHUB_REF='refs/heads/untrusted'}
   'wrong-event' {$env:GITHUB_EVENT_NAME='pull_request'}
   'wrong-owner' {$env:GITHUB_REPOSITORY_OWNER='other'}
   'wrong-actor' {$env:GITHUB_ACTOR='other'}
   'wrong-rerun-actor' {$env:GITHUB_TRIGGERING_ACTOR='other'}
   'missing-key' {Remove-Item Env:VERIFY_CREDENTIAL_TOKEN}
  }
  $success=$false
  try{& $script;$success=$true}catch{
   if($_.Exception.Message.Contains('synthetic-private-token')){throw 'Credential value escaped failure handling.'}
  }
  $expected=$case.EndsWith('-valid')
  if($success -ne $expected){throw "Unexpected outcome: $case"}
  if(Test-Path Env:VERIFY_CREDENTIAL_TOKEN){throw 'Credential remained in the environment.'}
  if($success){
   $text=Get-Content -Raw -LiteralPath $OutputPath;$metadata=$text | ConvertFrom-Json
   if($text.Contains('synthetic-private-token') -or $metadata.authentication -cne 'verified' -or $metadata.runtime_verified -ne $false -or $null -ne $metadata.PSObject.Properties['token_type']){throw 'Unsafe public metadata.'}
  }elseif(Test-Path -LiteralPath $OutputPath){throw 'Failed check wrote passing metadata.'}
  $results.Add(@{case=$case;expected_pass=$expected;actual_pass=$success;calls=$global:FixtureCalls.ToArray()})
 }
 $receipt=@{captured_at=[DateTimeOffset]::UtcNow.ToString('o');helper_copies=1;synthetic_cases=$results;real_credential_reads=$false;real_provider_calls=$false}
 Write-Output "PASS: $($results.Count) synthetic authentication and secret-sanitization cases."
}finally{
 Remove-Item -Recurse -Force -LiteralPath $directory
 foreach($name in @('VERIFY_CREDENTIAL_TOKEN','GITHUB_EVENT_NAME','GITHUB_REF','GITHUB_REPOSITORY_ID','GITHUB_REPOSITORY_OWNER','GITHUB_REPOSITORY','GITHUB_SHA','GITHUB_RUN_ID','GITHUB_ACTOR','GITHUB_TRIGGERING_ACTOR')){
  Remove-Item ('Env:'+$name) -ErrorAction SilentlyContinue
 }
}
