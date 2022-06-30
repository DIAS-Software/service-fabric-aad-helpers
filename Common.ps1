﻿<#
.VERSION
1.0.4

.SYNOPSIS
Common script, do not call it directly.
https://techcommunity.microsoft.com/t5/azure-active-directory-identity/azure-ad-change-management-simplified/ba-p/2967456
#>

function main () {
    if ($headers) {
        return
    }

    return get-RESTHeaders
}

function assert-notNull($obj, $msg) {
    if ($obj -eq $null -or $obj.Length -eq 0) { 
        Write-Warning $msg
        exit
    }
}

function call-graphApi($uri, $headers = $global:defaultHeaders, $body = '', $method = 'post') {
    try {
        $error.clear()
        $json = $body | ConvertTo-Json -Depth 99 -Compress
        $logHeaders = $headers.clone()
        $logHeaders.Authorization = $logHeaders.Authorization.substring(0,30) + '...'
        write-host "Invoke-WebRequest $uri -method $method -headers $($logHeaders | convertto-json) -body $($body | convertto-json -depth 99)" -ForegroundColor Green
        $result = Invoke-WebRequest $uri -Method $method -Headers $headers -Body $json
        $resultObj =  $result.Content | convertfrom-json
        $resultJson = $resultObj | convertto-json -depth 99
        write-host "Invoke-WebRequest result:$resultJson" -ForegroundColor cyan
        if($result.StatusCode -ne 200){
            switch($result.StatusCode){
                204 {
                    if($method -ieq 'patch'){
                        # successful patch
                        return $result
                    }
                    return $null
                }
                default:{
                    write-warning "unhandled status code:$($result.StatusCode) $($result.StatusDescription)"
                }
            }
        }
        return $resultObj
    }
    catch [System.Exception] {
        write-warning "call-graphApi exception:`r`n$($psitem.Exception.Message)`r`n$($error | out-string)`r`n$($psitem.ScriptStackTrace)"
        return $null
    }
}

function get-cloudInstance() {
    $isCloudInstance = $PSVersionTable.Platform -ieq 'unix' -and ($env:ACC_CLOUD)
    write-host "cloud instance: $isCloudInstance"
    return $isCloudInstance
}

function get-RESTHeaders() {
    $redirectUrl = "urn:ietf:wg:oauth:2.0:oob"

    if (get-cloudInstance) {
        $token = get-RESTHeadersCloud
    }
    else {
        $token = get-RESTHeadersGraph -tenantId $TenantId
    }
    
    $authHeader = @{
        'Content-Type'  = 'application/json'
        'Authorization' = 'Bearer ' + $token
        'ConsistencyLevel' = 'eventual'
    }

    write-host "auth header: $($authHeader | convertto-json)"
    return $authHeader
}

function get-RESTHeadersADAL() {
    $authenticationContext = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext]::new($authString, $false)
    $promptBehavior = [Microsoft.IdentityModel.Clients.ActiveDirectory.PromptBehavior]::RefreshSession
    $platformParameters = [Microsoft.IdentityModel.Clients.ActiveDirectory.PlatformParameters]::new($promptBehavior)

    $accessToken = $authenticationContext.AcquireTokenAsync($resourceUrl, $clientId, $redirectUrl, $platformParameters).Result.AccessToken
    return $accessToken
}

function get-RESTHeadersCloud() { 
    # https://docs.microsoft.com/en-us/azure/cloud-shell/msi-authorization
    $response = invoke-webRequest -method post `
        -uri 'http://localhost:50342/oauth2/token' `
        -body "resource=$resourceUrl" `
        -header @{'metadata' = 'true' }

    write-host $response | convertto-json
    $token = ($response | convertfrom-json).access_token
    return $token
}

function get-restAuthGraph($tenantId, $clientId, $scope, $uri) {
    # requires app registration api permissions with 'devops' added
    # so cannot use internally
    write-host "auth request" -ForegroundColor Green
    $error.clear()
    $uri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/devicecode"

    $Body = @{
        'client_id' = $clientId
        'scope'     = $scope
    }

    $params = @{
        ContentType = 'application/x-www-form-urlencoded'
        Body        = $Body
        Method      = 'post'
        URI         = $uri
    }
    
    Write-Verbose ($params | convertto-json)
    $error.Clear()
    write-host "invoke-restMethod $uri" -ForegroundColor Cyan
    $global:authresult = Invoke-RestMethod @params -Verbose -Debug
    write-host "auth result: $($global:authresult | convertto-json)"
    write-host "rest auth finished"

    return $global:authresult
}

function get-restTokenGraph($tenantId, $grantType, $clientId, $clientSecret, $scope) {
    # requires app registration
    # will retry on device code until complete

    write-host "token request" -ForegroundColor Green
    $global:logonResult = $null
    $error.clear()
    $uri = "https://login.windows.net/$tenantId/oauth2/v2.0/token"
    $headers = @{
        'content-type' = 'application/x-www-form-urlencoded'
        'accept'       = 'application/json'
    }

    if ($grantType -ieq 'urn:ietf:params:oauth:grant-type:device_code') {
        $global:authResult = get-restAuthGraph -tenantId $tenantId -clientId $clientId -scope $scope
        $Body = @{
            'client_id'   = $clientId
            'device_code' = $global:authresult.device_code
            'grant_type'  = $grantType 
        }
    }
    elseif ($grantType -ieq 'client_credentials') {
        $Body = @{
            'client_id'     = $clientId
            'client_secret' = $clientSecret
            'grant_type'    = $grantType 
        }
    }
    elseif ($grantType -ieq 'authorization_code') {
        $global:authResult = get-restAuthGraph -tenantId $tenantId -clientId $clientId -scope $scope
        $Body = @{
            'client_id'  = $clientId
            'code'       = $global:authresult.code
            'grant_type' = $grantType 
        }
    }

    $params = @{
        Headers = $headers 
        Body    = $Body
        Method  = 'Post'
        URI     = $uri
    }

    write-verbose ($params | convertto-json)
    write-host "invoke-restMethod $uri" -ForegroundColor Cyan

    $endTime = (get-date).AddSeconds($global:authresult.expires_in / 2)

    while ($endTime -gt (get-date)) {
        write-verbose "logon timeout: $endTime current time: $(get-date)"
        $error.Clear()

        try {
            $global:logonResult = Invoke-RestMethod @params -Verbose -Debug
            write-host "logon result: $($global:logonResult | convertto-json)"
            $global:accessToken = $global:logonResult.access_token
            $global:accessTokenExpiration = ((get-date).AddSeconds($global:logonResult.expires_in))
            return $global:accessToken
        }
        catch [System.Exception] {
            $errorMessage = ($_ | convertfrom-json)

            if ($errorMessage -and ($errorMessage.error -ieq 'authorization_pending')) {
                write-host "waiting for device token result..." -ForegroundColor Yellow
                write-host "$($global:authresult.message)" -ForegroundColor Green
                start-sleep -seconds $global:authresult.interval
            }
            else {
                write-host "exception: $($error | out-string)`r`n this: $($_)`r`n"
                write-host "logon error: $($errorMessage | convertto-json)"
                write-host "breaking"
                break
            }
        }
    }

    write-host "rest logon returning"
    return $global:accessToken
}

function get-RESTHeadersGraph($tenantId) {
    # Use common client 
    $clientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e' # well-known ps graph client id generated on connect
    $grantType = 'urn:ietf:params:oauth:grant-type:device_code' #'client_credentials', #'authorization_code'
    $scope = 'user.read openid profile Application.ReadWrite.All User.ReadWrite.All Directory.ReadWrite.All Directory.Read.All Domain.Read.All'
    if (!$global:accessToken -or ($global:accessTokenExpiration -lt (get-date)) -or $force) {
        $accessToken = get-restTokenGraph -tenantId $tenantId -grantType $grantType -clientId $clientId -scope $scope
    }
    return $accessToken
}

# Regional settings
switch ($Location) {
    "china" {
        $resourceUrl = "https://graph.chinacloudapi.cn"
        $authString = "https://login.partner.microsoftonline.cn/" + $TenantId
    }
    
    "us" {
        $resourceUrl = "https://graph.windows.net"
        $authString = "https://login.microsoftonline.us/" + $TenantId
    }

    default {
        $resourceUrl = "https://graph.microsoft.com"
        $authString = "https://login.microsoftonline.com/" + $TenantId
    }
}

$headers = main
$global:defaultHeaders = $headers

if ($ClusterName) {
    $WebApplicationName = $ClusterName + "_Cluster"
    #$WebApplicationUri = "https://$ClusterName"
    $NativeClientApplicationName = $ClusterName + "_Client"
}
