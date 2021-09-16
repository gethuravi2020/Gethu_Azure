# Add the name or names of the new VMs to be created.
$NewVMName = @('psdemo-pc001','psdemo-pc002','psdemo-pc003')


# Change this to the name of the resource group.
$ResourceGroupName = 'demo_group'


# Change this to the name of the VM image
$Image = Get-AzImage -ResourceGroupName WVD-RG -ImageName wvd-master-vm-image


# Change this to the preferred size of the VM to create.
$Size = 'Standard_DS1_v2'


# Specify the ports to open.
$OpenPorts = @('3389')


# Change this to the preferred local administrator name for the VM to create.
$AdminUserName = 'wsadmin'


# Change this to the preferred password for the local administrator.
$AdminPassword = ConvertTo-SecureString 'XLLBaNH7LJt2eUNr' -AsPlainText -Force


# ---------END MODIFICATION HERE---------


# This line create a secured credential object based on the username and password
$Credential = New-Object System.Management.Automation.PSCredential ($AdminUserName, $AdminPassword)


# This foreach block loops through the list of names in $NewVMName

# then create each new virtual machine using the $ImageName as the source image.

foreach ($Name in $NewVMName) {

New-AzVm -ResourceGroupName $resourceGroupName -Name $Name -Image $Image.id -Location "East US" -VirtualNetworkName "$($resourceGroupName)-vnet" -SecurityGroupName "$($Name)-nsg" -SubnetName 'default' -PublicIpAddressName "$($Name)-ip" -DomainNameLabel $Name -Size $Size -Credential $Credential -OpenPorts $OpenPorts

}