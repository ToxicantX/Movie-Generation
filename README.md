# Movie-Generation

基于 PowerShell、Python、GPT Image API、MiniMax H3、MiniMax Video API、Edge TTS 和 ComfyUI 的小说到影视短片流水线。配音和音画合成为可选后处理。

## 当前状态

- 项目状态入口：`manifests/current_pipeline_state.json`
- 当前素材：`搜神记` AI 短剧实验流水线
- 已完成：EP01 正式剪辑，以及 EP02 SC01-SC46 的测试模式正式片段；下一入口为 SC47
- 当前限制：大量片段使用 technical still fallback；正式发布前需要稳定 I2V 提供方重新生成，并进行最终人工创意审核

## 本地流水线

入口脚本为 `scripts/local_movie_pipeline.py`。`init` 会生成 `manifests/local_projects/<slug>/` 下的 16 个阶段清单和 `pipeline.json`，并构建对应的图片/视频工作流。阶段顺序与清单名称如下：

1. `concept`
2. `screenplay`
3. `screenplay_import`
4. `director_storyboard`
5. `episode_outline`
6. `scene_table`
7. `shot_table`
8. `audio_design`
9. `asset_catalog`
10. `image_prompts`
11. `image_generation`
12. `video_prompts`
13. `model_match`
14. `clip_generation`
15. `tts_generation`
16. `audio_mix`

方案、剧本、分镜、场景、资产清单和提示词等文本阶段使用控制台配置的 OpenAI 兼容文本 API，私有配置保存到 `config/text_api.local.json`；未配置时生成明确标记为 fallback 的规则草稿。图片首帧默认使用 OpenAI 兼容图片 API 与 `gpt-image-2`，通过控制台配置本机 API Key、Base URL、尺寸和质量。视频生成可在控制台切换本地与 API：本地通道使用 MiniMax H3 FL2VA I2V，API 通道使用 MiniMax/Hailuo 兼容的首帧图生视频契约。两种通道读取同一首帧和视频提示词，并写回同一 `clip_generation.json`。本地模型与输出约束为：

- W4A8 diffusion model：`minimax_h3_fl2va_pruned_w4a8_mixed.safetensors`
- Qwen3-VL MiniMax H3 text encoder、video VAE 和 audio VAE
- 8-step acceleration LoRA：`MiniMax-H3-FL2VA-Acc-8Step_pruned_comfy.safetensors`
- 736x416、24 fps；长度必须满足 `17*k+5`
- 默认生成 `length=243` 原始帧（10.125 秒），满足 `17k+5` 规则
- 默认只连接 `first_frame`，避免同图首尾约束把整段动作拉成慢动作
- 视频提示词要求正常实时速度和连续动作，同时保留人物身份与肢体稳定约束
- `Video Slice` 使用 `strict_duration=true` 将最终单文件严格裁为 10.000 秒
- `res_multistep` sampler、`simple` scheduler、`steps=8`
- 图片和视频提示词均限制为单一成年人物；视频采用低动作、单镜头身份锁定策略

脚本默认只创建清单和工作流；`run-image` 读取 Git 忽略的 `config/image_api.local.json` 并调用图片 API。`run-video` 读取 Git 忽略的 `config/video_api.local.json`：`local` 模式检查 ComfyUI 队列并提交单个 H3 工作流，不会清空或抢占已有队列；`api` 模式提交首帧和视频提示词、轮询任务并将成片下载到同一输出目录。`--no-ai` 可用于不访问文本模型的离线初始化。

## 目录

- `scripts/`：分镜、审核、I2V、回退、重生成、剪辑和状态脚本
- `manifests/`：项目状态、分镜计划、审核决定、队列及运行结果
- `workflows/`：图片 API 请求描述与 ComfyUI 视频工作流

API 首帧保存在 `G:\ComfyUI\output\local_projects`，视频、审核包和剪辑输出保存在 ComfyUI 输出目录，不进入 Git 仓库。小说源文件仍由工作区共享，默认位置为 `E:\workspace\ComfyUIProjects\搜神记.txt`。

## 常用命令

启动电影流水线控制台：

```powershell
powershell -ExecutionPolicy Bypass -File .\start_console.ps1
```

默认入口：`http://127.0.0.1:8200`。控制台提供项目总览、制作工作台、文本 AI、图片 API 与视频双通道配置、分镜与视频审核汇总、媒体预览和白名单诊断任务。API Key 只写入本机私有配置，读取接口不会回传密钥。

控制台的“项目管理”使用 PostgreSQL 保存项目名称、标识、小说源、生命周期和当前阶段，Redis 缓存项目列表并在写入后主动失效。现有 `manifests/local_projects/*/pipeline.json` 会自动登记到项目库。阶段清单、提示词、工作流描述、审核记录和媒体路径继续保留为 JSON/文件，这是有意采用的混合存储：PostgreSQL 负责需要查询和更新的业务事实，Redis 负责可丢弃的读取缓存，JSON 负责可追溯、可由脚本独立消费的生成产物。

### 本地 Docker 部署

Docker 只运行电影控制台、Edge TTS 和 FFmpeg，继续复用宿主机 `G:\ComfyUI` 的 MiniMax H3。执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\start_docker.ps1
```

Docker 入口为 `http://127.0.0.1:8206/`。Compose 同时运行 PostgreSQL 和 Redis；持久化数据位于 `data/postgres/` 与 `data/redis/`。`config/`、`manifests/`、`workflows/` 和 `logs/` 均绑定到本地项目目录，`G:\ComfyUI\output` 映射为容器内 `/comfy-output`。启动脚本在 ComfyUI 未运行时使用 `--listen 0.0.0.0 --lowvram` 启动它，使 Docker bridge 可以访问 `host.docker.internal:8188`。

停止控制台：

```powershell
docker compose down
```

本地流水线 CLI 示例（参数以脚本当前实现为准）：

```powershell
python .\scripts\local_movie_pipeline.py init .\搜神记.txt --slug demo_project --no-ai
python .\scripts\local_movie_pipeline.py show --slug demo_project
python .\scripts\local_movie_pipeline.py build-workflows --pipeline .\manifests\local_projects\demo_project\pipeline.json
python .\scripts\local_movie_pipeline.py run-image --pipeline .\manifests\local_projects\demo_project\pipeline.json --shot-id demo_project-ep01-sc01-sh01
python .\scripts\local_movie_pipeline.py run-video --pipeline .\manifests\local_projects\demo_project\pipeline.json --shot-id demo_project-ep01-sc01-sh01
python .\scripts\local_movie_pipeline.py run-tts --pipeline .\manifests\local_projects\demo_project\pipeline.json --shot-id demo_project-ep01-sc01-sh01
python .\scripts\local_movie_pipeline.py mix-audio --pipeline .\manifests\local_projects\demo_project\pipeline.json --shot-id demo_project-ep01-sc01-sh01
```

生成当前状态报告，不访问 ComfyUI：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_ai_short_drama_status_report.ps1 -SkipComfyProbe
```

运行 EP02 SC01 分镜审核到 I2V 的安全门禁流程：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_ep02_sc01_storyboard_to_i2v_pipeline.ps1
```

运行迁移后回归检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_i2v_contract.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test_storyboard_review_decisions.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test_prompt_secret_hygiene.ps1 -AllowBusyQueue
```

## 外部依赖

- ComfyUI：`http://127.0.0.1:8188`
- ComfyUI 根目录：`G:\ComfyUI`
- GPT Image API：默认 `https://api.openai.com/v1/images/generations`，也可配置兼容端点
- MiniMax Video API（可选）：默认 `https://api.minimax.io/v1/video_generation`，也可配置兼容端点
- PowerShell 7 或 Windows PowerShell
- Python 3（部分剪辑和探测脚本需要 OpenCV）
- Edge TTS（可选，`pip install edge-tts`）与 FFmpeg（可选音画合成）

## 安全边界

- API key 只从运行环境或 Git 忽略的 `config/image_api.local.json`、`config/video_api.local.json` 读取，不写入清单、工作流、接口响应或 Notion；不要提交密钥、`.env`、真实环境配置或运行日志。
- 项目 slug 和镜头 ID 使用白名单校验；小说必须位于工作区内，并使用 `.md`、`.novel`、`.text` 或 `.txt` 扩展名。
- 媒体预览只允许访问项目目录、`G:\ComfyUI\output\AIShortDrama` 或本地流水线专属的 `G:\ComfyUI\output\local_projects` 内受支持文件。
- 控制台项目状态来自 `manifests/local_projects/*/pipeline.json`；合法的生成任务才会启动后台进程。
- 本地生成可能消耗较高显存和时间，运行前应确认 ComfyUI 队列为空闲。

不要提交 API 密钥、真实环境配置、生成视频或运行日志。
