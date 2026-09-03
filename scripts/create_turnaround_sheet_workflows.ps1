param(
    [string]$PlanPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\character_turnaround_sheet_plan.json",
    [string]$WorkflowDir = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\turnaround_sheet_workflow_create_result.json",
    [string]$ImageModel = "gpt-image-2",
    [string]$ImageSize = "1536x1024"
)

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Plan file not found: $PlanPath"
}

$plan = Get-Content -Path $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$created = @()
$negative = "Chinese text, gibberish labels, modern UI, modern fashion, anime, cartoon, child, teenager, minor, plastic skin, sci-fi, western knight armor, excessive glowing fantasy armor, inconsistent faces, duplicated heads, missing full body, cropped feet, watermark, logo"

foreach ($character in $plan.priority_characters) {
    $workflowPath = Join-Path $WorkflowDir "$($character.id.ToLowerInvariant())_turnaround_sheet_v001.json"
    $prompt = @"
Create a production-grade character turnaround reference sheet for an ancient Chinese mythic fantasy short drama.

Character: $($character.name) / $($character.id).
Design lock: $($character.design_lock).

Layout requirements: one large realistic face portrait on the left; eight full-body views across the main board: front, front-left 45 degrees, left side, back-left 45 degrees, back, back-right 45 degrees, right side, front-right 45 degrees. Add lower detail panels for costume fabric, belt, pouch, hair silhouette, sleeves, footwear, and key props. Use a clean dark cinematic reference-board background with subtle bronze dividers. Make the same adult character consistent across every view. Full body visible including feet. No readable text labels; use visual panels only.

Style: cinematic realistic face, natural fabric texture, ancient Great Wilderness Chinese mythic drama, restrained lighting, high detail.
"@

    $workflow = [ordered]@{
        client_id = "codex-ai-short-drama"
        prompt = [ordered]@{
            "1" = [ordered]@{
                class_type = "OpenAICompatibleImageGenerate"
                inputs = [ordered]@{
                    prompt = $prompt
                    model = $ImageModel
                    size = $ImageSize
                    negative_prompt = $negative
                }
            }
            "2" = [ordered]@{
                class_type = "SaveImage"
                inputs = [ordered]@{
                    images = @("1", 0)
                    filename_prefix = $character.sheet_prefix
                }
            }
        }
    }

    $workflow | ConvertTo-Json -Depth 20 | Set-Content -Path $workflowPath -Encoding UTF8
    $created += [ordered]@{
        character_id = $character.id
        workflow = $workflowPath
        expected_output = "G:\ComfyUI\output\$($character.sheet_prefix)_00001_.png"
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    plan_path = $PlanPath
    created = $created
}
New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 12
