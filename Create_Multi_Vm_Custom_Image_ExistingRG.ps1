#VM_Provision
$NewVMName = @('Testgethu301-VM','Testgethu302-VM')
$rg = "AZ-RG-DEMO-01"
$vnet   = Get-AzVirtualNetwork -ResourceGroupName Gethu-Admin-RG -Name Gethu-Admin-RG-vnet
$subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name default
$OpenPorts = @('3389')
$cred = Get-Credential
foreach ($Name in $NewVMName) {

  $Dnsname= $Name.Substring(0,$Name.Length -3).ToLower()
  $PIP = New-AzPublicIpAddress `
    -Name $Dnsname `
	-DomainNameLabel $Dnsname `
	-ResourceGroupName $rg `
	-Location eastus `
	-AllocationMethod Dynamic
  
  $nic = New-AzNetworkInterface `
    -Name "$($name)-nic" `
    -ResourceGroupName $rg `
    -Location EastUS `
    -SubnetId $subnet.Id
  $vm = New-AzVMConfig `
    -VMName $Name `
    -VMSize Standard_DS2_v2
  Set-AzVMOperatingSystem `
    -VM $vm `
    -Windows `
    -ComputerName $name `
    -Credential $cred
  Set-AzVMSourceImage `
    -VM $vm `
    -Id $(Get-AzImage -ResourceGroupName WVD-RG -ImageName 'wvd-master-vm-image').id
  Add-AzVMNetworkInterface `
    -VM $vm `
    -Id $nic.Id
  Set-AzVMBootDiagnostic `
    -VM $vm `
    -Disable
	
  $tag = @{$Name=$Name}
   
  New-AzVM -ResourceGroupName $rg -Location EastUS -VM $vm #-OpenPorts $OpenPorts 
  
  $avm = Get-AzVM -ResourceGroupName $rg -Name $name
  
  Set-AzResource -ResourceId  $avm.id -Tag $tag -Force
  }
