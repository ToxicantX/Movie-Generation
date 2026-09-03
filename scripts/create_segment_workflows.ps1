param(
    [string]$PlanPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc02_storyboard_plan.json",
    [string]$WorkflowDir = "E:\workspace\ComfyUIProjects\Movie-Generation\workflows",
    [string]$ResultPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\segment_workflow_create_result.json",
    [string]$ImageModel = "gpt-image-2",
    [string]$ImageSize = "1536x1024",
    [string]$GeminiModel = "gemini-3.1-pro",
    [string]$GeminiBaseUrl = "http://127.0.0.1:7860",
    [string]$GeminiEnvPath = "E:\workspace\DockerProjects\Gemini-API\.env",
    [int]$GeminiRequestTimeoutSeconds = 2400
)

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Plan file not found: $PlanPath"
}

$plan = Get-Content -Path $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$negativeImage = "modern city, market street, beggar bowl, coins, poverty imagery, sci-fi, western medieval armor, European castle, anime, cartoon, plastic skin, neon cyberpunk, overdesigned armor, text, watermark, logo, child, teenager, minor, school age, cliff-edge danger, falling, injury, gore, distorted hands, melted face"
$created = @()

foreach ($shot in $plan.shots) {
    $suffix = ($shot.shot_id -replace '^TEST_', '').ToLowerInvariant()
    $storyboardWorkflowPath = Join-Path $WorkflowDir "$($suffix)_storyboard_v001.json"
    $videoWorkflowPath = Join-Path $WorkflowDir "$($suffix)_i2v_v001.json"
    $storyboardOutputPath = "G:\ComfyUI\output\$($shot.storyboard_filename_prefix)_00001_.png"

    $storyboardWorkflow = [ordered]@{
        client_id = "codex-ai-short-drama"
        prompt = [ordered]@{
            "1" = [ordered]@{
                class_type = "OpenAICompatibleImageGenerate"
                inputs = [ordered]@{
                    prompt = $shot.storyboard_prompt
                    model = $ImageModel
                    size = $ImageSize
                    negative_prompt = $negativeImage
                }
            }
            "2" = [ordered]@{
                class_type = "SaveImage"
                inputs = [ordered]@{
                    images = @("1", 0)
                    filename_prefix = $shot.storyboard_filename_prefix
                }
            }
        }
    }

    if ($shot.storyboard_reference_image) {
        $storyboardWorkflow.prompt."1".inputs.reference_image_paths = [string]$shot.storyboard_reference_image
    }

    $videoWorkflow = [ordered]@{
        client_id = "codex-ai-short-drama"
        prompt = [ordered]@{
            "1" = [ordered]@{
                class_type = "GeminiAPIVideoGenerate"
                inputs = [ordered]@{
                    model = $GeminiModel
                    prompt = $shot.video_prompt
                    image_path = $storyboardOutputPath
                    filename_prefix = $shot.video_filename_prefix
                    base_url = $GeminiBaseUrl
                    reference_field = "file_ids"
                    video_reference_mode = "experimental_file_ids"
                    reference_image_paths = ""
                    aspect_ratio = "16:9"
                    request_timeout_seconds = $GeminiRequestTimeoutSeconds
                    api_key_env_path = $GeminiEnvPath
                }
            }
        }
    }

    New-Item -ItemType Directory -Path $WorkflowDir -Force | Out-Null
    $storyboardWorkflow | ConvertTo-Json -Depth 20 | Set-Content -Path $storyboardWorkflowPath -Encoding UTF8
    $videoWorkflow | ConvertTo-Json -Depth 20 | Set-Content -Path $videoWorkflowPath -Encoding UTF8

    $created += [ordered]@{
        shot_id = $shot.shot_id
        storyboard_workflow = $storyboardWorkflowPath
        video_workflow = $videoWorkflowPath
        expected_storyboard_path = $storyboardOutputPath
    }
}

$result = [ordered]@{
    updated = (Get-Date).ToString("s")
    plan_path = $PlanPath
    workflow_dir = $WorkflowDir
    created = $created
}
New-Item -ItemType Directory -Path (Split-Path $ResultPath) -Force | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 12
