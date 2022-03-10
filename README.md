# How To: Authenticate HTTP requests from ADF to Azure Function with AAD Managed Service Identity

## Intro

This walk-through describes how to use Azure Managed Service Identity to
authenticate HTTP requests issued by an instance of Azure Data Factory to an
instance of Azure Function App. To achieve this we need to configure a number of
things:

1. Create Azure AD App Registration and set some settings for it (including
   Service Principle, Exposed API, Scope, and App Role);
2. Grant the App Role to ADF's MSI
3. Configure Azure Function App to use Azure AD as Identity Provider
4. Adjust ADF Web Activity or ADF Azure Function Linked Service to use
   MSI authentication and provide reference to the "resource" (a.k.a. token
   audience value)

## Configure Azure Active Directory App Registration and grant access to ADF's MSI

### Related links

- [Create an app registration in Azure AD for your App Service app](https://docs.microsoft.com/en-us/azure/app-service/configure-authentication-provider-aad#-create-an-app-registration-in-azure-ad-for-your-app-service-app)
- [Stackoverflow: Authorizing Azure Function App Http endpoint from Data Factory](https://stackoverflow.com/questions/65178711/authorizing-azure-function-app-http-endpoint-from-data-factory/65192318#65192318)

### Manual steps

**Note:** See the next section for the automated approach.

**Note:** These instructions are largely based on materials referenced above.

1. In Azure Portal - find your Function App and note:
   - Function App name (e.g.: `myfuncapp`)
   - Function App URL (e.g. `https://myfuncapp.azurewebsites.net`)
2. In Azure Portal - select Azure Active Directory, then go to the App registrations tab and select "New registration".
3. In the Register an application page, enter a Name for your app registration (e.g. `aad-app-myfuncapp`)
4. In Redirect URI, select Web and type `<app-url>/.auth/login/aad/callback`. (For example, `https://myfuncapp.azurewebsites.net/.auth/login/aad/callback`)
5. Select Register.
6. After the app registration is created, copy the Application (client) ID and the Directory (tenant) ID for later.
7. Select Authentication. Under Implicit grant and hybrid flows, enable ID tokens. Select Save.
8. (Optional) Select Branding. In Home page URL, enter the URL of your Function App and select Save.
9. Configure "Expose an API" section:
   1. Select "Expose an API", and click "Set" next to "Application ID URI". Enter the value in a format `api://<aad-app-name>` (e.g.: `api://aad-app-myfuncapp`). See [AppId URI configuration](https://docs.microsoft.com/en-us/azure/active-directory/develop/security-best-practices-for-app-registration#appid-uri-configuration) documentation page for more details. The value is automatically saved.
   2. Select Add a scope.
   3. In Add a scope, the Application ID URI is the value you set in a previous step. Select Save and continue.
   4. In Scope name, enter `user_impersonation`.
   5. In the text boxes, enter the consent scope name and description you want users to see on the consent page. For example, enter `Access <func-app-name>` (`Access myfuncapp`) in both fields.
   6. Select Add scope.
10. Add App role:
    1. Select "App role" and click "Create app role" at the top of the pane.
    2. Enter display name. For example `<aad-app-name>-function-caller` (e.g.: `aad-app-myfuncapp-function-caller`).
    3. Set "Allowed member types" - `Applications`
    4. Set the unique "Value" - `function.call` (or any other)
    5. Add any description
    6. Leave "Do you want to enable this app role?" checked.
    7. Click "Apply"
11. Assign the role to your ADF MSI:
    1. Make sure you have [AzureAD powershell module](https://docs.microsoft.com/en-us/powershell/azure/active-directory/install-adv2?view=azureadps-2.0#installing-the-azure-ad-module) installed.
    2. Use this snippet to assign the role (also available [here](./Assign-AppRoleToAdfMsi.ps1)):

```ps
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
```

### Automation

This repo includes [the script](./Configure-AADAppForAzFuncAndAdf.ps1) to automate all steps outlined above.

Usage instructions:

1. Download the [Configure-AADAppForAzFuncAndAdf.ps1](./Configure-AADAppForAzFuncAndAdf.ps1) script.
2. Make sure you have [AzureAD powershell module](https://docs.microsoft.com/en-us/powershell/azure/active-directory/install-adv2?view=azureadps-2.0#installing-the-azure-ad-module) installed.
3. Open the PowerShell console.
4. Execute as follows (**Note**: The script will open a browser windows for interactive authentication to provided Azure AD tenant):

```cmd
powershell .\Configure-AADAppForAzFuncAndAdf.ps1 -pTenantId <your_tenant_id> -pFunctionAppName <your_func_app_name> -pAadAppName <your_aad_app_name> -pAdfName <my_adf_name>
```

5. Note the script output (in yellow and magenta color) - use these instructions to configure the Function App (see next section):

```
Use these values to configure Authentication for Azure Function App 202203FuncAuthTest:
----------------------------------------------------------------------------------------
App registration type: 'Provide the details of an existing app registration'
Application (client) ID: <Application (client) ID (Guid)>
Client secret: leave blank
Issuer URL: https://sts.windows.net/<Directory (tenant) ID>/v2.0
Allowed token audiences: api://<AAD App Name>
Restrict access: 'Require authentication'
Unauthenticated requests: 'HTTP 401 Unauthorized: recommended for APIs'
Token store: Unchecked (off)
----------------------------------------------------------------------------------------
NOTE: Use the audience value as the resource identifier in ADF's Web Activity or AzFunc LS.
```

## Configure Azure Function App - Authentication and Identity Provider

### Related links

- [Enable Azure Active Directory in your App Service app](https://docs.microsoft.com/en-us/azure/app-service/configure-authentication-provider-aad#-create-an-app-registration-in-azure-ad-for-your-app-service-app)

### Manual steps

1. In Azure Portal - find your Function App.
2. Navigate to the "Authentication" pane.
3. Click Add identity provider.
4. Select "Microsoft" in the identity provider dropdown.
5. Complete the configuration as follows (replace values in `<...>`):
   1. App registration type: "Provide the details of an existing app registration"
   2. Application (client) ID: `<Application (client) ID (Guid)>`
   3. Client secret: leave blank
   4. Issuer URL: `https://sts.windows.net/<Directory (tenant) ID>/v2.0`
   5. Allowed token audiences: `api://<AAD App Name>`
   6. Restrict access: "Require authentication"
   7. Unauthenticated requests: "HTTP 401 Unauthorized: recommended for APIs"
   8. Token store: Unchecked (off)
   9. Click "Add" (at the bottom of the page)

### Automation

Not implemented yet

## Amend Azure Data Factory (Web Activity or Azure Function Linked Service)

### Web Activity

1. In Azure Portal - find your instance of Azure Data Factory
2. Open Azure Data Factory Studio
3. In "Author" pane - find the Web Activity that calls your Azure Function
4. Make sure the URL includes your app name: `https://<Your Azure Function App Name>.azurewebsites.net/...`
5. If your Azure Function is configured to use "function" authentication - make sure you provide `code` value in query string.
6. Edit Web Activity settings as follows:
   1. Authentication: "Managed Identity"
   2. Resource: `api://<AAD App Name>`

### Azure Function Linked Service

1. In Azure Portal - find your instance of Azure Data Factory
2. Open Azure Data Factory Studio
3. In "Manage" pane - find the linked service (Type: Compute, Azure Function) that references your Azure Function App.
4. Edit settings as follows (or re-create the linked service if its not editable, you may also need to switch your pipeline activities):
   1. Authentication method: "Managed Identity"
   2. Resource ID: `api://<AAD App Name>`
