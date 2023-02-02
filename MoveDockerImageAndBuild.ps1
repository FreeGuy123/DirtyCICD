### Variables
$RootName = "YourProjectName"
$BuildName = $RootName + ":latest"
$YourName = "YourNameHere"
$ACRName = "YourAzureContainerRegistry"
$MsiId = "ClientIdOfYourUserManagedIdenity"
$AzureResourceId = "https://management.azure.com/"
$ACRResourceGroup = "AzureContainerRegistryResourceGroup"
$ACRSubscriptionId = "YourSubscriptionID"
$AKSResourceId = "6dae42f8-4368-4678-94ff-3960e28e3630"
$AKSRestAPIUrl = "YourAKSClustRestAPIAbsolutePath"
$AKSNameSpaceName = $RootName
$AKSDeploymentName = $RootName + "deployment"

### Verify Docker Is Running and If Not start it
If ("Running" -eq $( Get-Service | Where-Object { $_.name -eq "com.docker.service" } ).Status) { Write-host "Build Service Running" -ForegroundColor Green } 
else { Write-host "Build Service Not Started:" -ForegroundColor Red -NoNewline  ; Write-host " Starting" -ForegroundColor Green; Start-Service -Name "com.docker.service"; If ("Running" -ne $(Get-Service | Where-Object { $_.name -eq "com.docker.service" }).Status) { Write-host "Build Service Failed To Start" -ForegroundColor Red; Exit } else { Write-host "Build Service Running" -ForegroundColor Green } }

### Build Image
$PassThrough = Start-Process docker -ArgumentList 'build', "--pull", "--rm", "-f", "Dockerfile", "-t $BuildName", '"."', '--quiet' -NoNewWindow -PassThru -Wait 
if ( 0 -eq $PassThrough.ExitCode ) { Write-host "Build Created" -ForegroundColor Green } else { Write-host "Build Failed: Exit" -ForegroundColor Red; exit }

### Function to verify Returns before continuing
function ShouldIContinue { param ( $ReturnToCheck ); if ("OK" -eq $ReturnToCheck.InvokeRestAPIResult.StatusCode -or "Created" -eq $ReturnToCheck.InvokeRestAPIResult.StatusCode ) { Write-host "$($ReturnToCheck.Command) Was Successfull" -ForegroundColor Green } else { Write-host "$($ReturnToCheck.Command) FAILED" -ForegroundColor Red; Exit } }

### Get Bearer Token Function MSI
$HttpClient = [System.Net.Http.HttpClient]::new(); 
function GetBearerToken {
    param ( $ResourceId, $Command )
    $HttpRequestMessage = [System.Net.Http.HttpRequestMessage]::new(); $HttpRequestMessage.Headers.Add('Metadata', 'True'); $HttpRequestMessage.Content = [System.Net.Http.StringContent]::new( $null, [System.Text.Encoding]::UTF8, 'application/json')
    $HttpRequestMessage.Method = 'GET'; $HttpRequestMessage.RequestUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=" + $ResourceId + "&client_Id=" + $MsiId
    $InvokedReturn = $HttpClient.SendAsync($HttpRequestMessage).GetAwaiter().GetResult(); $Return = [ordered]@{ Command = $Command ; InvokeRestAPIResult = $InvokedReturn; InvokeRestAPIContent = $($InvokedReturn).Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -Depth 100 }
    ShouldIContinue $Return; $BearerTokenHeaderReturn = @( [ordered]@{ Type = 'authorization'; Value = $("Bearer " + $Return.InvokeRestAPIContent.access_token) } )
    return $BearerTokenHeaderReturn
}

### Get Bearer Token for MGMT
$BearerTokenHeader = GetBearerToken $AzureResourceId "Get-BearerToken" 

### Function To Execute Container Registry Requests
### Documentation https://learn.microsoft.com/en-us/rest/api/containerregistry/registries
function CreateHttpRequestMessageAndInvokeRestAPI {
    param( $Method, $Body, $RequestAction, $Command )
    $RequestUri = "https://management.azure.com/subscriptions/$ACRSubscriptionId/resourceGroups/$ACRResourceGroup/providers/Microsoft.ContainerRegistry/registries/$ACRName" + $RequestAction + "?api-version=2019-05-01"
    $HttpRequestMessage = [System.Net.Http.HttpRequestMessage]::new(); $HttpRequestMessage.Content = [System.Net.Http.StringContent]::new( $( $Body | ConvertTo-Json -depth 100 ), [System.Text.Encoding]::UTF8, 'application/json' );
    $HttpRequestMessage.Method = $Method; $HttpRequestMessage.RequestUri = $RequestUri.tostring(); $HttpRequestMessage.Headers.Add( $( $BearerTokenHeader.Type ), $( $BearerTokenHeader.Value ));
    $InvokedReturn = $HttpClient.SendAsync($HttpRequestMessage).GetAwaiter().GetResult(); $Return = [ordered]@{ Command = $Command ; InvokeRestAPIResult = $InvokedReturn; InvokeRestAPIContent = $($InvokedReturn).Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -Depth 100 }
    ShouldIContinue $Return
    return $Return
}

### Sets Admin Account to Enable and Logs Me As the Enabler
$ACREnableAdminUserMethod = "PATCH"; $ACREnableAdminUserBody = [ordered]@{ tags = [ordered]@{ adminUserEnabledBy = "Enabled by $YourName $(Get-Date -Format "MMddyyyy-HHmmss")" }; properties = [ordered]@{ adminUserEnabled = $true } } 
$null = CreateHttpRequestMessageAndInvokeRestAPI $ACREnableAdminUserMethod $ACREnableAdminUserBody $null "ACREnableAdminUser"

### Cycles Password 1 on the Registry Admin Account
$ACRRegenerateCredentialMethod = "POST"; $ACRRegenerateCredentialBody = @{ name = "Password" }; $ACRRegenerateCredentialRequestAction = "/regenerateCredential"
$null = CreateHttpRequestMessageAndInvokeRestAPI $ACRRegenerateCredentialMethod $ACRRegenerateCredentialBody $ACRRegenerateCredentialRequestAction "ACRRegenerateCredential1"

### Cycles Password 2 on the Registry Admin Account
$ACRRegenerateCredentialBody2 = @{ name = "Password2" }
$ACRRegenerateCredentialReturn2 = CreateHttpRequestMessageAndInvokeRestAPI $ACRRegenerateCredentialMethod $ACRRegenerateCredentialBody2 $ACRRegenerateCredentialRequestAction "ACRRegenerateCredential2"

### Logs In to ACR
$PassThrough = Start-Process docker -ArgumentList "login $ACRName.azurecr.io", "-u $($ACRRegenerateCredentialReturn2.InvokeRestAPIContent.username)", "--password $($($ACRRegenerateCredentialReturn2.InvokeRestAPIContent.Passwords | Where-Object { $_.Name -eq "password" }).value)" -NoNewWindow -PassThru -Wait
if ( 0 -eq $PassThrough.ExitCode ) { Write-host "Docker Login SuccessFull" -ForegroundColor Green } else { Write-host "Docker Login Failed: Exit" -ForegroundColor Red; exit }

### Tags Image to be pushed
$PassThrough = Start-Process docker -ArgumentList "tag", "$BuildName $ACRName.azurecr.io/$BuildName" -NoNewWindow -PassThru -Wait
if ( 0 -eq $PassThrough.ExitCode ) { Write-host "Docker Tagging SuccessFull" -ForegroundColor Green } else { Write-host "Docker Tagging Failed: Exit" -ForegroundColor Red; exit }

### Pushes Image To ACR
$PassThrough = Start-Process docker -ArgumentList "push", "$ACRName.azurecr.io/$BuildName" -NoNewWindow -PassThru -Wait
if ( 0 -eq $PassThrough.ExitCode ) { Write-host "Docker Image Push SuccessFull" -ForegroundColor Green } else { Write-host "Docker Image Push Failed: Exit" -ForegroundColor Red; exit }

### Logout of ACR
$PassThrough = Start-Process docker -ArgumentList "logout $ACRName.azurecr.io" -NoNewWindow -PassThru -Wait
if ( 0 -eq $PassThrough.ExitCode ) { Write-host "Docker Logout SuccessFull" -ForegroundColor Green } else { Write-host "Docker Logout Failed: Exit" -ForegroundColor Red; exit }

### Clears Creds
$ACRRegenerateCredentialReturn2 = $null

### Cycles Password 1 on the Registry Admin Account
$ACRRegenerateCredentialMethod = "POST"; $ACRRegenerateCredentialBody = @{ name = "Password" }; $ACRRegenerateCredentialRequestAction = "/regenerateCredential"
$null = CreateHttpRequestMessageAndInvokeRestAPI $ACRRegenerateCredentialMethod $ACRRegenerateCredentialBody $ACRRegenerateCredentialRequestAction "ACRRegenerateCredential1"

### Cycles Password 2 on the Registry Admin Account
$ACRRegenerateCredentialBody2 = @{ name = "Password2" }
$null = CreateHttpRequestMessageAndInvokeRestAPI $ACRRegenerateCredentialMethod $ACRRegenerateCredentialBody2 $ACRRegenerateCredentialRequestAction "ACRRegenerateCredential2"

### Sets Admin Account to Disable and Logs Me As the Disabler
$ACRDisableAdminUserBody = [ordered]@{ tags = [ordered]@{ adminUserEnabledBy = "Disabled By $YourName $(Get-Date -Format "MMddyyyy-HHmmss")" }; properties = [ordered]@{ adminUserEnabled = $false } }
$null = CreateHttpRequestMessageAndInvokeRestAPI $ACREnableAdminUserMethod $ACRDisableAdminUserBody $null "ACRDisableAdminUser"

### AKS HttpClient Setup - Ignore Self Signed Certificate Errors
try { Add-Type $('using System; using System.Net.Http; using System.Net.Security; using System.Security.Cryptography; using System.Security.Cryptography.X509Certificates; using System.Text; public class CertIgnore { public static Func<HttpRequestMessage, X509Certificate2, X509Chain, SslPolicyErrors, bool> GetServerCertificateValidationCallback(string expect = null) { return (sender, cert, chain, errors) => true; } }') } catch {}
$AKSHttpClientHandler = [System.Net.Http.HttpClientHandler]::new(); $AKSHttpClientHandler.ServerCertificateCustomValidationCallback = [CertIgnore]::GetServerCertificateValidationCallback(); $AksHttpClient = [System.Net.Http.HttpClient]::new($Global:AKSHttpClientHandler); $AKSBearerTokenHeader = GetBearerToken $AKSResourceId "Get-AKSBearerToken"

### Function To Execute AKS Requests
### Documentation https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.22/
function CreateAKSHttpRequestMessageAndInvokeRestAPI {
    param( $Body, $CommandToExecute )
    try {
        $Command = $CommandToExecute[0] + "." + $CommandToExecute[1]; $i = 0;
        if ( "NameSpace" -eq $CommandToExecute[0]) { $ApiVersion = '/api/v1/namespaces' }; 
        if ( "NameSpace" -eq $CommandToExecute[0] -and ( "Get" -eq $CommandToExecute[1] -or "Delete" -eq $CommandToExecute[1]  ) ) { $ApiVersion = $ApiVersion + "/" + $AKSNameSpaceName };
        if ( "Deployment" -eq $CommandToExecute[0]) { $ApiVersion = "/apis/apps/v1/namespaces/$AKSNameSpaceName/deployments" }; 
        if ( "Deployment" -eq $CommandToExecute[0] -and ("Get" -eq $CommandToExecute[1] -or "Delete" -eq $CommandToExecute[1] ) ) { $ApiVersion = $ApiVersion + "/" + $AKSDeploymentName };
        $HttpRequestMessage = [System.Net.Http.HttpRequestMessage]::new(); 
        $HttpRequestMessage.Content = [System.Net.Http.StringContent]::new( $( $body | ConvertTo-Json -depth 100 ), [System.Text.Encoding]::UTF8, 'application/json' );
        $Method = "$($([ordered]@{ Create = 'POST'; Get = 'GET'; Delete = 'DELETE' }).$($CommandToExecute[1]))"
        $HttpRequestMessage.Method = $Method; 
        $HttpRequestMessage.RequestUri = "https://$AKSRestAPIUrl" + $ApiVersion; 
        $HttpRequestMessage.Headers.Add( $( $AKSBearerTokenHeader.Type ), $( $AKSBearerTokenHeader.Value ));
        $InvokeReturnFull = $AksHttpClient.SendAsync($HttpRequestMessage).GetAwaiter().GetResult(); 
        $InvokeReturn = $($InvokeReturnFull).Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -Depth 100;
        $Return = [ordered]@{ Command = $Command ; InvokeRestAPIResult = $InvokeReturnFull; InvokeRestAPIContent = $InvokeReturn }; If ("Get" -ne $CommandToExecute[1] ) { ShouldIContinue $Return };
        if ( $CommandToExecute[0] -eq "Namespace" -and $CommandToExecute[1] -eq "Create" -and $InvokeReturn.status.phase -eq "Active") {}
        elseif ( $CommandToExecute[0] -eq "Deployment" -and $CommandToExecute[1] -eq "Delete" -and $InvokeReturn.status -eq "Success" ) {}
        elseif ( ($CommandToExecute[1] -eq "Get" -and $InvokeReturn.code -eq 404) -or ( $CommandToExecute[1] -eq "Get" -and $InvokeReturnFull.statuscode.Value__ -eq 404 ) ) {}
        elseif ( ($CommandToExecute[1] -eq "Get" -and $InvokeReturn.code -eq 200) -or ( $CommandToExecute[1] -eq "Get" -and $InvokeReturnFull.statuscode.Value__ -eq 200 ) ) {}
        elseif ( $InvokeReturnFull.statuscode.Value__ -eq 409 -or $InvokeReturn.code -eq 409 ) { throw "$Command.Exception.Conflict.409" } 
        elseif ( $InvokeReturnFull.statuscode.Value__ -eq 405 -or $InvokeReturn.code -eq 405 ) { throw "$Command.Exception.MethodNotAllowed.405" }
        else { 
            do {
                if ( "NameSpace" -eq $CommandToExecute[0] -and "Delete" -eq $CommandToExecute[1] ) { $ApiVersion = "/api/v1/namespaces/$AKSNameSpaceName" };
                if ( "Deployment" -eq $CommandToExecute[0] -and "Create" -eq $CommandToExecute[1] ) { $ApiVersion = "/apis/apps/v1/namespaces/$AKSNameSpaceName/deployments/$AKSDeploymentName" };
                $HttpRequestMessage = [System.Net.Http.HttpRequestMessage]::new(); 
                $HttpRequestMessage.Content = [System.Net.Http.StringContent]::new( $null, [System.Text.Encoding]::UTF8, 'application/json' );
                $HttpRequestMessage.Method = 'GET' 
                $HttpRequestMessage.RequestUri = "https://$AKSRestAPIUrl" + $ApiVersion; 
                $HttpRequestMessage.Headers.Add( $( $AKSBearerTokenHeader.Type ), $( $AKSBearerTokenHeader.Value ));
                Write-host "$Command Sleep( 10 )" -ForegroundColor DarkYellow; Start-Sleep 10;
                $InvokeReturnAsyncFull = $AksHttpClient.SendAsync( $HttpRequestMessage ).GetAwaiter().GetResult();
                $InvokeReturnAsync = $InvokereturnAsyncFull.Content.ReadAsStringAsync().GetAwaiter().GetResult() | convertfrom-json -Depth 100; [void]$i++
            } until ( 
            ($CommandToExecute[0] -eq "Namespace" -and $CommandToExecute[1] -eq "Delete" -and $null -eq $InvokeReturnAsync.status.phase) -or
            ($CommandToExecute[0] -eq "Deployment" -and $CommandToExecute[1] -eq "Create" -and $InvokeReturnAsync.status.conditions.message -match "has successfully progressed") -or ($i -ge 120)
            ); 
            if ($i -ge 120) { throw "$Command.Async.TimeOut" } 
            Write-host "$Command Complete" -ForegroundColor Green
        };
        If ("Get" -eq $CommandToExecute[1] ) { Return $InvokeReturnFull }
    }
    catch { Write-host "$error" }
}

### Get AKS NameSpace
$CommandToExecute = @( "NameSpace", "Get" )
$AKSGetResult = CreateAKSHttpRequestMessageAndInvokeRestAPI $null $CommandToExecute
If ( 404 -ne $($AKSGetResult.Content.ReadAsStringAsync().GetAwaiter().GetResult() | convertfrom-json -Depth 100).code ) {
    ### Deletes AKS NameSpace
    $CommandToExecute = @( "NameSpace", "Delete" )
    CreateAKSHttpRequestMessageAndInvokeRestAPI $null $CommandToExecute
}

### Creates AKS NameSpace
$CommandToExecute = @( "NameSpace", "Create" )
$AKSCreateNameSpace = [ordered]@{ kind = "Namespace"; apiVersion = "v1"; metadata = @{ name = $AKSNameSpaceName; labels = @{ "kubernetes.io/metadata.name" = $AKSNameSpaceName } } }
CreateAKSHttpRequestMessageAndInvokeRestAPI $AKSCreateNameSpace $CommandToExecute

### Creates AKS Deployment
$CommandToExecute = @( "Deployment", "Create" )
$AKSCreateDeployment = [ordered]@{
    apiVersion = "apps/v1"; kind = "Deployment";
    metadata = [ordered]@{ name = $RootName + "deployment"; namespace = $RootName; labels = [ordered]@{ app = "$RootName-app" } };
    spec = [ordered]@{
        replicas = 3; selector = [ordered]@{ matchLabels = [ordered]@{ app = "$RootName-app" } };
        template = [ordered]@{
            metadata = [ordered]@{ labels = [ordered]@{ app = "$RootName-app" } };
            spec     = [ordered]@{
                restartPolicy  = "Always";
                containers     = @( [ordered]@{ name = "$RootName-container"; image = "$ACRName.azurecr.io/$BuildName"; ports = @( [ordered]@{ containerPort = 80 } ) } );
                readinessProbe = [ordered]@{ httpGet = [ordered]@{ path = "/healthz"; port = 80; scheme = "HTTP" }; initialDelaySeconds = 5; periodSeconds = 5 };
                livenessProbe  = [ordered]@{ httpGet = [ordered]@{ path = "/healthz"; port = 80; scheme = "HTTP" }; initialDelaySeconds = 15; periodSeconds = 20 }
            } 
        } 
    }
}
CreateAKSHttpRequestMessageAndInvokeRestAPI $AKSCreateDeployment $CommandToExecute
