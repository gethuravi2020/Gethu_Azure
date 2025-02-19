$subscriptionName = ""           
$servicePrinciaplApplicationId = ""
$servicePrincipalSecret = ""
$tenantId = ""

 
$SecurePassword = ConvertTo-SecureString -String $servicePrincipalSecret -AsPlainText -Force
$ApplicationId = $servicePrinciaplApplicationId
$Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ApplicationId, $SecurePassword
Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $Credential

write-Host $subscriptionName
Select-AzSubscription -Subscription $subscriptionName
