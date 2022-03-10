$tenantId = '<Tenant ID (GUID)>'
$adfName = '<ADF Instance Name>'
$aadAppName = '<AAD App Name>'
$appRoleValue = '<App Role Value>'

# This may take some time - should open a browser pop-up window
Connect-AzureAD -TenantId $tenantId

$adfServicePrincipal = Get-AzureADServicePrincipal -Filter "displayName eq '${adfName}'"
$aadAppServicePrincipal = Get-AzureADServicePrincipal -Filter "displayName eq '${aadAppName}'"
$appRole = $aadAppServicePrincipal.AppRoles | Where-Object {$_.Value -eq $appRoleValue}

New-AzureADServiceAppRoleAssignment `
  -ObjectId $adfServicePrincipal.ObjectId `
  -PrincipalId $adfServicePrincipal.ObjectId `
  -ResourceId $aadAppServicePrincipal.ObjectId `
  -Id $appRole.Id
