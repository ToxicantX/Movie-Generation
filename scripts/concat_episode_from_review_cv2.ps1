param(
    [string]$ReviewPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_consistency_review.json",
    [string]$OutputPath = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC01_test_cv2_v001.mp4",
    [string]$ManifestPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_episode_cut_result.json",
    [string]$PythonPath = "python"
)

& $PythonPath "E:\workspace\ComfyUIProjects\Movie-Generation\scripts\concat_episode_from_review_cv2.py" $ReviewPath $OutputPath $ManifestPath
exit $LASTEXITCODE
