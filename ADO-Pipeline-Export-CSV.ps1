# Define Azure DevOps organization URL and personal access token
$orgUrl = "https://dev.azure.com/YourOrganization"
$pat = "YourPersonalAccessToken"

# Convert personal access token to base64
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($pat)"))

# API endpoint to get list of pipelines
$uri = "$orgUrl/_apis/pipelines?api-version=6.0-preview.1"

# Invoke REST API to get pipelines
$pipelines = Invoke-RestMethod -Uri $uri -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)} -Method Get

# Create a new Excel object
$excel = New-Object -ComObject Excel.Application
$workbook = $excel.Workbooks.Add()
$worksheet = $workbook.Worksheets.Item(1)

# Set headers
$headers = "Pipeline ID", "Name", "URL"
$col = 1
$headers | ForEach-Object {
    $worksheet.Cells.Item(1, $col) = $_
    $col++
}

# Populate data
$row = 2
$pipelines.value | ForEach-Object {
    $worksheet.Cells.Item($row, 1) = $_.id
    $worksheet.Cells.Item($row, 2) = $_.name
    $worksheet.Cells.Item($row, 3) = $_.url
    $row++
}

# Save Excel file
$excel.Visible = $true
$excel.DisplayAlerts = $false
$workbook.SaveAs("C:\Path\To\Pipelines.xlsx")
$excel.Quit()
