<#
.SYNOPSIS
  Adds a neww AAD application registration, configures it in a way that allows
  using it for Function App's authentication. Also grants access to the ADF
  instance

.PARAMETER pTenantId
  AAD's tenant id

.PARAMETER pAadAppName
  AAD app's name (e.g. `app-aad-<function app name>`). This value is also used
  to shape the token audience URI (we'll use it as follows: `api://<AAD app name>`)

.PARAMETER pFunctionAppName
  Azure Function app's name - used to nuild some URLs and role names

.PARAMETER pAdfName
  ADF instance's name - we use it to grant access to AzFunc for ADF's MSI

.EXAMPLE
  PS C:\> .\Configure-AADAppForAzFuncAndAdf.ps1 `
    -pTenantId <your_tenant_id> `
    -pFunctionAppName <my_func_app_name> `
    -pAadAppName <my_aad_app_name> `
    -pAdfName <my_adf_name>

#>

param(
  $pTenantId,
  $pFunctionAppName,
  $pAadAppName,
  $pAdfName
)

# ************************* helper functions ***********************************
function DoConnect-AzureAD {
  Write-Host "Connecting to AAD (TenantId = $tenantId)..." -ForegroundColor Green
  Write-Host `
    "Please wait for a credential window to open - this may take some time..." `
    -ForegroundColor Green
  $dummy = Connect-AzureAD -TenantId $tenantId
}

function Get-AADApp{
  param(
    $name
  )

  $app = Get-AzureADApplication -Filter "displayName eq '${name}'"

  if($app -is [array]){
    throw "Too many apps with the same name - can't continue"
  }

  return $app
}

function Get-AADSvcPrincipalByName{
  param(
    $name
  )
  return Get-AzureADServicePrincipal -Filter "displayName eq '${name}'"
}

function Get-AADSvcPrincipalByAppId{
  param(
    $appId
  )
  return Get-AzureADServicePrincipal -Filter "AppId eq '${appId}'"
}

# ************************* main function **************************************

function main{
  param(
    $tenantId,
    $functionAppName,
    $aadAppName,
    $adfName
  )

    # ************************* build names and vars *******************************
  
    $names = [PSCustomObject]@{
      redirectUrl = "https://$functionAppName.azurewebsites.net/.auth/login/aad/callback"
      homePageUrl = "https://$functionAppName.azurewebsites.net"
      apiURI = "api://${aadAppName}"
      IssuerURL = "https://sts.windows.net/${tenantId}/v2.0"
    }
    
    $scopeSettings = [PSCustomObject]@{
      name = "user_impersonation"
      desc = "Access $functionAppName"
      isEnabled = $true
      type = "Admin"
    }
    
    $roleSettings = [PSCustomObject]@{
      displayName = "${functionAppName}-function-caller"
      value = "function.call"
      isEnabled = $true
      allowedMemberTypes = @("application")
    }
    
    Write-Host "Names:" -ForegroundColor Green
    Write-Host $names
    Write-Host "Scope settings:" -ForegroundColor Green
    Write-Host $scopeSettings
    Write-Host "Role settings:" -ForegroundColor Green
    Write-Host $roleSettings
  
  # ************************* login/connect **************************************

  try {
    Write-Host "Checking connection status..." -ForegroundColor Green
    $aadTenantDetail = Get-AzureADTenantDetail
    if($aadTenantDetail.ObjectId -eq $tenantId){
      Write-Host "Already connected (TenantId = $tenantId)" -ForegroundColor Green
    }
    else {
      Write-Host "We need to reconnect to another tenant" -ForegroundColor Green
      DoConnect-AzureAD
    }
  }
  catch [Microsoft.Open.Azure.AD.CommonLibrary.AadNeedAuthenticationException] 
  { 
    Write-Host "You're not connected."; 
    DoConnect-AzureAD
  }
   
  # ************************* create app (if not exists) *************************
  
  Write-Host "Looking for AAD app ${aadAppName}" -ForegroundColor Green
  $aadApp = Get-AADApp -name $aadAppName
  
  if(-not $aadApp){
    Write-Host "AAD App not found, creating" -ForegroundColor Green
    $aadApp = New-AzureADApplication `
      -DisplayName $aadAppName `
      -Homepage $names.homePageUrl `
      -ReplyUrls $names.redirectUrl
  }
  else {
    Write-Host "App located:" -ForegroundColor Green
    Write-Host "App ObjectId = $($aadApp.ObjectId)"
    Write-Host "App AppId = $($aadApp.AppId)"
    Write-Host "App displayName = $($aadApp.displayName)"
  }
  
  # ************************* create service principal (if not exists) ***********
  
  $aadApp = Get-AADApp -name $aadAppName
  
  $aadServicePrincipal = Get-AADSvcPrincipalByAppId -appId $aadApp.AppId
    
  if(-not $aadServicePrincipal){
    Write-Host "AAD Service Principal not found, creating" -ForegroundColor Green
    New-AzureADServicePrincipal -AppId $aadApp.AppId
  }
  
  # ************************* set app settings (always) **************************
  
  Write-Host "Setting app params" -ForegroundColor Green
  
  $dummy = Set-AzureADApplication `
    -ObjectId $aadApp.ObjectId `
    -DisplayName $aadAppName `
    -Homepage $names.homePageUrl `
    -ReplyUrls $names.redirectUrl `
    -IdentifierUris $names.apiURI
  
  # ************************* [re]set scopes (always) ****************************
  
  $aadApp = Get-AADApp -name $aadAppName
  
  $currentScopes = New-Object `
    System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.OAuth2Permission]
  
  $aadApp.Oauth2Permissions | ForEach-Object { $currentScopes.Add($_) }
  $currentScopes | ForEach-Object { $_.IsEnabled = $false }
  
  Write-Host "Disabling existing scopes" -ForegroundColor Green
  
  $dummy = Set-AzureADApplication `
    -ObjectId $aadApp.ObjectId `
    -Oauth2Permissions $currentScopes
  
  Write-Host "Creating new scopes" -ForegroundColor Green
  
  $scope = New-Object Microsoft.Open.AzureAD.Model.OAuth2Permission
  $scope.Id = New-Guid
  $scope.Value = $scopeSettings.name
  $scope.AdminConsentDisplayName = $scopeSettings.desc
  $scope.AdminConsentDescription = $scopeSettings.desc
  $scope.IsEnabled = $scopeSettings.isEnabled
  $scope.Type = $scopeSettings.type
  
  $newScopes = New-Object `
    System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.OAuth2Permission]
  $newScopes.Add($scope)
  
  $dummy = Set-AzureADApplication `
    -ObjectId $aadApp.ObjectId `
    -Oauth2Permissions $newScopes
  
  # ************************* create app role (if not exists) ********************
  
  Write-Host "Looking for app roles" -ForegroundColor Green
  $currentAppRole = $aadApp.AppRoles | 
    Where-Object {$_.Value -eq $roleSettings.value}
  
  if(-not $currentAppRole){
    Write-Host "App role not found - creating a new one" -ForegroundColor Green

    # create new AppRole object and set properties
    $newAppRole = [Microsoft.Open.AzureAD.Model.AppRole]::new()
    $newAppRole.DisplayName = $roleSettings.displayName
    $newAppRole.Description = $roleSettings.displayName
    $newAppRole.Value = $roleSettings.value
    $newAppRole.Id = New-Guid
    $newAppRole.IsEnabled = $roleSettings.isEnabled
    $newAppRole.AllowedMemberTypes = $roleSettings.allowedMemberTypes
    
    # Add new AppRole and apply changes to Application object
    $appRoles = $aadApp.AppRoles
    $appRoles += $newAppRole
  
    $dummy = Set-AzureADApplication `
      -ObjectId $aadApp.ObjectId `
      -AppRoles $appRoles 
  }
  else {
    Write-Host "App role already exists - skipping" -ForegroundColor Green
  }
  
  # ************************* grant app role to ADF's MSI  ***********************
  
  $adfServicePrincipal = Get-AADSvcPrincipalByName -name $adfName  
  
  if(-not $adfServicePrincipal){
    throw "Cannot locate ADF's Service Principal"
  }
  
  $aadAppServicePrincipal = Get-AADSvcPrincipalByAppId -appId $aadApp.AppId
  
  # This would be strange, but still...
  if(-not $aadAppServicePrincipal){
    throw "Cannot locate AAD App's Service Principal"
  }
  
  $aadApprole = $aadAppServicePrincipal.AppRoles | 
    Where-Object {$_.Value -eq $roleSettings.value}
  
  # This would be strange, but still...
  if(-not $aadApprole){
    throw "Cannot locate App Role with value $($roleSettings.value)"
  }
  
  $currentAssignment = Get-AzureADServiceAppRoleAssignment `
    -ObjectId $aadAppServicePrincipal.ObjectId |
      Where-Object {$_.PrincipalDisplayName -eq $adfName}
  
  if(-not $currentAssignment){
    Write-Host "No role assignment detected, creatine a new one" `
      -ForegroundColor Green
    $newRoleAssignment = New-AzureADServiceAppRoleAssignment `
      -ObjectId $adfServicePrincipal.ObjectId `
      -PrincipalId $adfServicePrincipal.ObjectId `
      -ResourceId $aadAppServicePrincipal.ObjectId `
      -Id $aadApprole.Id
  
    Write-Host "New role assignment:" -ForegroundColor Green
    Write-Host $newRoleAssignment  
  }
  else {
    Write-Host "Role assignment already exists - skipping" `
      -ForegroundColor Green
  }
  
  # ************************* output app details *********************************
  
  $aadApp = Get-AADApp -name $aadAppName
  
  Write-Host "Application object:" -ForegroundColor Green
  Write-Host $aadApp
  Write-Host "Application scopes:" -ForegroundColor Green
  Write-Host $aadApp.Oauth2Permissions
  Write-Host "Application roles:" -ForegroundColor Green
  Write-Host $aadApp.AppRoles

  Write-Host "All Done!" -ForegroundColor Green
  Write-Host "" -ForegroundColor Green


  Write-Host "Use these values to configure Authentication for Azure Function App ${functionAppName}:" -ForegroundColor Yellow
  Write-Host "----------------------------------------------------------------------------------------" -ForegroundColor Yellow
  Write-Host "App registration type: 'Provide the details of an existing app registration'" -ForegroundColor Magenta
  Write-Host "Application (client) ID: $($aadApp.AppId)" -ForegroundColor Magenta
  Write-Host "Client secret: leave blank" -ForegroundColor Magenta
  Write-Host "Issuer URL: $($names.IssuerURL)" -ForegroundColor Magenta
  Write-Host "Allowed token audiences: $($names.apiURI)" -ForegroundColor Magenta
  Write-Host "Restrict access: 'Require authentication'" -ForegroundColor Magenta
  Write-Host "Unauthenticated requests: 'HTTP 401 Unauthorized: recommended for APIs'" -ForegroundColor Magenta
  Write-Host "Token store: Unchecked (off)" -ForegroundColor Magenta
  Write-Host "----------------------------------------------------------------------------------------" -ForegroundColor Yellow
  Write-Host "NOTE: Use the audience value as the resource identifier in ADF's Web Activity or AzFunc LS." -ForegroundColor Yellow
  
}

main `
  -tenantId $pTenantId `
  -functionAppName $pFunctionAppName `
  -aadAppName $pAadAppName `
  -adfName $pAdfName 
