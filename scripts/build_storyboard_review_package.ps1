param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review.json",
    [string]$OutputDir = "G:\ComfyUI\output\AIShortDrama\review_packages\SSJ_EP02_SC01_STORYBOARD",
    [string]$ManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep02_sc01_storyboard_review_package.json",
    [string]$PythonPath = "python"
)

& $PythonPath "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\build_storyboard_review_package.py" $ReviewPath $OutputDir $ManifestPath
exit $LASTEXITCODE
