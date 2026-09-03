param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
    [string]$OutputDir = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP01_SC01",
    [string]$ManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_review_package.json",
    [string]$PythonPath = "python"
)

& $PythonPath "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\build_review_package.py" $ReviewPath $OutputDir $ManifestPath
exit $LASTEXITCODE
