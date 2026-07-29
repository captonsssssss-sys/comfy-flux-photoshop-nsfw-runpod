# syntax=docker/dockerfile:1.7

FROM farmerfarmit/bitcoin:v6

USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV COMFYUI_PATH=/default-comfyui-bundle/ComfyUI

# Проверяем curl и python3.
# При необходимости устанавливаем через доступный пакетный менеджер.
RUN set -eux; \
    if ! command -v curl >/dev/null 2>&1; then \
        if command -v apt-get >/dev/null 2>&1; then \
            apt-get update; \
            apt-get install -y --no-install-recommends curl ca-certificates; \
            rm -rf /var/lib/apt/lists/*; \
        elif command -v apk >/dev/null 2>&1; then \
            apk add --no-cache curl ca-certificates; \
        elif command -v dnf >/dev/null 2>&1; then \
            dnf install -y curl ca-certificates; \
            dnf clean all; \
        elif command -v microdnf >/dev/null 2>&1; then \
            microdnf install -y curl ca-certificates; \
            microdnf clean all; \
        elif command -v yum >/dev/null 2>&1; then \
            yum install -y curl ca-certificates; \
            yum clean all; \
        else \
            echo "ERROR: curl отсутствует и пакетный менеджер не найден"; \
            exit 1; \
        fi; \
    fi; \
    command -v python3; \
    curl --version; \
    python3 --version

# Проверяем расположение ComfyUI.
RUN set -eux; \
    test -d "${COMFYUI_PATH}"; \
    test -d "${COMFYUI_PATH}/models"; \
    test -d "${COMFYUI_PATH}/user"; \
    echo "ComfyUI found at: ${COMFYUI_PATH}"

# Очищаем ВСЕ workflow-папки внутри известных папок ComfyUI.
# Это удаляет старые workflow, оставшиеся в базовом образе.
RUN set -eux; \
    for ROOT in \
        "${COMFYUI_PATH}" \
        "/ComfyUI" \
        "/workspace/ComfyUI" \
        "/opt/ComfyUI"; \
    do \
        if [ -d "${ROOT}" ]; then \
            find "${ROOT}" -type d -name "workflows" -print0 | \
            while IFS= read -r -d '' WORKFLOW_DIR; do \
                echo "Cleaning workflow directory: ${WORKFLOW_DIR}"; \
                find "${WORKFLOW_DIR}" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -exec rm -rf {} +; \
            done; \
        fi; \
    done

# Очищаем старые checkpoints, LoRA и upscale-модели.
# SAM и Ultralytics сохраняем, потому что они нужны этому workflow.
RUN set -eux; \
    mkdir -p \
        "${COMFYUI_PATH}/models/checkpoints" \
        "${COMFYUI_PATH}/models/loras" \
        "${COMFYUI_PATH}/models/upscale_models" \
        "${COMFYUI_PATH}/user/default/workflows"; \
    find "${COMFYUI_PATH}/models/checkpoints" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec rm -rf {} +; \
    find "${COMFYUI_PATH}/models/loras" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec rm -rf {} +; \
    find "${COMFYUI_PATH}/models/upscale_models" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec rm -rf {} +

# GonzaLomoXL checkpoint.
# Скачиваем v60PhotoXLDMD, но сохраняем под названием,
# которое прописано внутри workflow.
RUN curl -L \
    --fail \
    --retry 10 \
    --retry-delay 10 \
    --connect-timeout 30 \
    "https://huggingface.co/dedsmetana/GonzaLomoXLFluxPony/resolve/main/gonzalomoXLFluxPony_v60PhotoXLDMD.safetensors" \
    -o "${COMFYUI_PATH}/models/checkpoints/gonzalomoXLFluxPony_v60newPhotoXLDMD.safetensors"

# Realism LoRA By Stable Yogi.
RUN curl -L \
    --fail \
    --retry 10 \
    --retry-delay 10 \
    --connect-timeout 30 \
    "https://huggingface.co/descho/kaia/resolve/c183a62b9df2a2d18deaba19b51a5a325d572bd8/Realism%20Lora%20By%20Stable%20Yogi_V3_Lite.safetensors" \
    -o "${COMFYUI_PATH}/models/loras/Realism Lora By Stable Yogi_V3_Lite.safetensors"

# 4x UltraSharp.
RUN curl -L \
    --fail \
    --retry 10 \
    --retry-delay 10 \
    --connect-timeout 30 \
    "https://huggingface.co/lokCX/4x-Ultrasharp/resolve/main/4x-UltraSharp.pth" \
    -o "${COMFYUI_PATH}/models/upscale_models/4x-UltraSharp.pth"

# Копируем workflow во временную папку.
COPY FLUX_PHOTOSHOP_NSFW.json /tmp/FLUX_PHOTOSHOP_NSFW.json

# Исправляем ошибку:
# resolution: '1.0' not in [...]
#
# Удаляем несовместимую FluxResolutionNode и её связи.
# EmptyLatentImage уже содержит прямые значения:
# width  = 896
# height = 1536
RUN python3 - <<'PY'
import json
from pathlib import Path

source = Path("/tmp/FLUX_PHOTOSHOP_NSFW.json")

with source.open("r", encoding="utf-8") as file:
    workflow = json.load(file)

nodes = workflow.get("nodes", [])
links = workflow.get("links", [])

resolution_nodes = {
    node.get("id")
    for node in nodes
    if node.get("type") == "FluxResolutionNode"
}

removed_link_ids = {
    link[0]
    for link in links
    if len(link) >= 2 and link[1] in resolution_nodes
}

workflow["nodes"] = [
    node
    for node in nodes
    if node.get("id") not in resolution_nodes
]

workflow["links"] = [
    link
    for link in links
    if link[0] not in removed_link_ids
]

for node in workflow["nodes"]:
    for node_input in node.get("inputs", []):
        if node_input.get("link") in removed_link_ids:
            node_input["link"] = None

    for node_output in node.get("outputs", []):
        output_links = node_output.get("links")
        if isinstance(output_links, list):
            node_output["links"] = [
                link_id
                for link_id in output_links
                if link_id not in removed_link_ids
            ]

empty_latent_nodes = [
    node
    for node in workflow["nodes"]
    if node.get("type") == "EmptyLatentImage"
]

if not empty_latent_nodes:
    raise RuntimeError("EmptyLatentImage не найден")

for node in empty_latent_nodes:
    values = node.get("widgets_values", [])

    if len(values) >= 3:
        values[0] = 896
        values[1] = 1536
        node["widgets_values"] = values

    for node_input in node.get("inputs", []):
        if node_input.get("name") in {"width", "height"}:
            node_input["link"] = None

if any(
    node.get("type") == "FluxResolutionNode"
    for node in workflow["nodes"]
):
    raise RuntimeError("FluxResolutionNode не была удалена")

with source.open("w", encoding="utf-8") as file:
    json.dump(
        workflow,
        file,
        ensure_ascii=False,
        separators=(",", ":"),
    )

print("FluxResolutionNode removed")
print("Resolution fixed to 896x1536")
PY

# Устанавливаем только один workflow.
RUN set -eux; \
    install -m 0644 \
        "/tmp/FLUX_PHOTOSHOP_NSFW.json" \
        "${COMFYUI_PATH}/user/default/workflows/FLUX_PHOTOSHOP_NSFW.json"; \
    rm -f "/tmp/FLUX_PHOTOSHOP_NSFW.json"

# Проверяем checkpoint, LoRA и upscale-модель.
RUN set -eux; \
    test -s "${COMFYUI_PATH}/models/checkpoints/gonzalomoXLFluxPony_v60newPhotoXLDMD.safetensors"; \
    test -s "${COMFYUI_PATH}/models/loras/Realism Lora By Stable Yogi_V3_Lite.safetensors"; \
    test -s "${COMFYUI_PATH}/models/upscale_models/4x-UltraSharp.pth"

# Проверяем размеры скачанных файлов.
RUN set -eux; \
    CHECKPOINT_SIZE="$(stat -c%s "${COMFYUI_PATH}/models/checkpoints/gonzalomoXLFluxPony_v60newPhotoXLDMD.safetensors")"; \
    LORA_SIZE="$(stat -c%s "${COMFYUI_PATH}/models/loras/Realism Lora By Stable Yogi_V3_Lite.safetensors")"; \
    UPSCALER_SIZE="$(stat -c%s "${COMFYUI_PATH}/models/upscale_models/4x-UltraSharp.pth")"; \
    echo "Checkpoint size: ${CHECKPOINT_SIZE} bytes"; \
    echo "LoRA size: ${LORA_SIZE} bytes"; \
    echo "Upscaler size: ${UPSCALER_SIZE} bytes"; \
    test "${CHECKPOINT_SIZE}" -gt 5000000000; \
    test "${LORA_SIZE}" -gt 100000000; \
    test "${UPSCALER_SIZE}" -gt 1000000

# Проверяем SAM и Ultralytics-модели из базового образа.
RUN set -eux; \
    find "${COMFYUI_PATH}/models" \
        -type f \
        -name "sam_vit_b_01ec64.pth" \
        -print \
        -quit | grep -q .; \
    find "${COMFYUI_PATH}/models" \
        -type f \
        -name "face_yolov8m.pt" \
        -print \
        -quit | grep -q .; \
    find "${COMFYUI_PATH}/models" \
        -type f \
        -name "hand_yolov8s.pt" \
        -print \
        -quit | grep -q .; \
    find "${COMFYUI_PATH}/models" \
        -type f \
        -name "person_yolov8m-seg.pt" \
        -print \
        -quit | grep -q .

# Проверяем workflow и отсутствие проблемной ноды.
RUN python3 - <<'PY'
import json
from pathlib import Path

workflow_path = Path(
    "/default-comfyui-bundle/ComfyUI/"
    "user/default/workflows/FLUX_PHOTOSHOP_NSFW.json"
)

with workflow_path.open("r", encoding="utf-8") as file:
    workflow = json.load(file)

node_types = {
    node.get("type")
    for node in workflow.get("nodes", [])
}

if "FluxResolutionNode" in node_types:
    raise RuntimeError("FluxResolutionNode всё ещё находится в workflow")

required_types = {
    "CheckpointLoaderSimple",
    "LoraLoader",
    "UpscaleModelLoader",
    "SAMLoader",
    "UltralyticsDetectorProvider",
    "FaceDetailer",
    "EmptyLatentImage",
}

missing = required_types - node_types

if missing:
    raise RuntimeError(
        f"В workflow отсутствуют необходимые ноды: {sorted(missing)}"
    )

print("Workflow validation passed")
PY

# Финальная проверка:
# во всех workflow-папках ComfyUI должен остаться только один JSON.
RUN set -eux; \
    find "${COMFYUI_PATH}" \
        -type f \
        -path "*/workflows/*.json" \
        -print; \
    WORKFLOW_COUNT="$(find "${COMFYUI_PATH}" \
        -type f \
        -path "*/workflows/*.json" | wc -l)"; \
    echo "Total workflow JSON count: ${WORKFLOW_COUNT}"; \
    test "${WORKFLOW_COUNT}" -eq 1; \
    test -f "${COMFYUI_PATH}/user/default/workflows/FLUX_PHOTOSHOP_NSFW.json"
