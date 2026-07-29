# syntax=docker/dockerfile:1.7

FROM farmerfarmit/bitcoin:v6

USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV COMFYUI_PATH=/default-comfyui-bundle/ComfyUI

# Проверяем curl.
# Если curl отсутствует — устанавливаем через доступный пакетный менеджер.
RUN set -eux; \
    if command -v curl >/dev/null 2>&1; then \
        echo "curl already installed"; \
    elif command -v apt-get >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends curl ca-certificates; \
        rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null 2>&1; then \
        apk add --no-cache curl ca-certificates bash; \
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
    curl --version; \
    python3 --version

# Создаём загрузчик, который:
# 1. принудительно использует HTTP/1.1;
# 2. сохраняет незавершённый файл как .part;
# 3. после обрыва продолжает скачивание;
# 4. делает до 30 попыток.
RUN <<'SCRIPT'
set -eux

cat > /usr/local/bin/download-model <<'EOF'
#!/usr/bin/env bash

set -u

URL="$1"
OUTPUT="$2"
PART="${OUTPUT}.part"

MAX_ATTEMPTS=30
ATTEMPT=1

mkdir -p "$(dirname "${OUTPUT}")"

while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
    echo "=================================================="
    echo "Download attempt ${ATTEMPT}/${MAX_ATTEMPTS}"
    echo "URL: ${URL}"
    echo "Output: ${OUTPUT}"

    if [ -s "${PART}" ]; then
        PART_SIZE="$(stat -c%s "${PART}")"
        echo "Partial file found: ${PART_SIZE} bytes"
        echo "Continuing download..."
    else
        echo "Starting download from zero..."
    fi

    if curl \
        --http1.1 \
        --location \
        --fail \
        --show-error \
        --connect-timeout 30 \
        --speed-time 300 \
        --speed-limit 1024 \
        --continue-at - \
        --output "${PART}" \
        "${URL}"; then

        if [ -s "${PART}" ]; then
            mv "${PART}" "${OUTPUT}"

            FINAL_SIZE="$(stat -c%s "${OUTPUT}")"

            echo "Download finished successfully"
            echo "Final size: ${FINAL_SIZE} bytes"

            exit 0
        fi
    fi

    echo "Attempt ${ATTEMPT} failed"

    ATTEMPT=$((ATTEMPT + 1))

    if [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; then
        echo "Waiting 15 seconds before continuing..."
        sleep 15
    fi
done

echo "ERROR: download failed after ${MAX_ATTEMPTS} attempts"
exit 1
EOF

chmod +x /usr/local/bin/download-model
SCRIPT

# Проверяем расположение ComfyUI.
RUN set -eux; \
    test -d "${COMFYUI_PATH}"; \
    test -d "${COMFYUI_PATH}/models"; \
    test -d "${COMFYUI_PATH}/user"; \
    echo "ComfyUI found at: ${COMFYUI_PATH}"

# Очищаем все workflow-папки внутри ComfyUI,
# чтобы в образе не осталось workflow из базового образа.
RUN set -eux; \
    find "${COMFYUI_PATH}" \
        -type d \
        -name "workflows" \
        -print0 | \
    while IFS= read -r -d '' WORKFLOW_DIR; do \
        echo "Cleaning workflow directory: ${WORKFLOW_DIR}"; \
        find "${WORKFLOW_DIR}" \
            -mindepth 1 \
            -maxdepth 1 \
            -exec rm -rf {} +; \
    done

# Создаём необходимые папки и очищаем старые модели.
RUN set -eux; \
    mkdir -p \
        "${COMFYUI_PATH}/user/default/workflows" \
        "${COMFYUI_PATH}/models/checkpoints" \
        "${COMFYUI_PATH}/models/loras" \
        "${COMFYUI_PATH}/models/upscale_models"; \
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
# Скачиваем файл v60PhotoXLDMD,
# но сохраняем под названием из workflow.
RUN /usr/local/bin/download-model \
    "https://huggingface.co/dedsmetana/GonzaLomoXLFluxPony/resolve/main/gonzalomoXLFluxPony_v60PhotoXLDMD.safetensors" \
    "${COMFYUI_PATH}/models/checkpoints/gonzalomoXLFluxPony_v60newPhotoXLDMD.safetensors"

# Realism LoRA By Stable Yogi.
RUN /usr/local/bin/download-model \
    "https://huggingface.co/descho/kaia/resolve/c183a62b9df2a2d18deaba19b51a5a325d572bd8/Realism%20Lora%20By%20Stable%20Yogi_V3_Lite.safetensors" \
    "${COMFYUI_PATH}/models/loras/Realism Lora By Stable Yogi_V3_Lite.safetensors"

# 4x UltraSharp.
RUN /usr/local/bin/download-model \
    "https://huggingface.co/lokCX/4x-Ultrasharp/resolve/main/4x-UltraSharp.pth" \
    "${COMFYUI_PATH}/models/upscale_models/4x-UltraSharp.pth"

# Копируем workflow во временную папку.
COPY FLUX_PHOTOSHOP_NSFW.json /tmp/FLUX_PHOTOSHOP_NSFW.json

# Исправляем несовместимую FluxResolutionNode.
#
# В исходном workflow в ней записано значение "1.0",
# которое новая версия ноды не принимает.
#
# Удаляем FluxResolutionNode и её связи.
# В EmptyLatentImage устанавливаем прямые значения 896 × 1536.
RUN python3 - <<'PY'
import json
from pathlib import Path

workflow_path = Path("/tmp/FLUX_PHOTOSHOP_NSFW.json")

with workflow_path.open("r", encoding="utf-8") as file:
    workflow = json.load(file)

nodes = workflow.get("nodes", [])
links = workflow.get("links", [])

resolution_node_ids = {
    node.get("id")
    for node in nodes
    if node.get("type") == "FluxResolutionNode"
}

if not resolution_node_ids:
    print("FluxResolutionNode not found — no removal required")
else:
    removed_link_ids = {
        link[0]
        for link in links
        if len(link) >= 2 and link[1] in resolution_node_ids
    }

    workflow["nodes"] = [
        node
        for node in nodes
        if node.get("id") not in resolution_node_ids
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
    raise RuntimeError("EmptyLatentImage не найден в workflow")

for node in empty_latent_nodes:
    values = node.get("widgets_values", [])

    if len(values) < 3:
        raise RuntimeError(
            f"У EmptyLatentImage неправильные widgets_values: {values}"
        )

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
    raise RuntimeError("FluxResolutionNode всё ещё находится в workflow")

with workflow_path.open("w", encoding="utf-8") as file:
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

# Проверяем скачанные модели.
RUN set -eux; \
    test -s "${COMFYUI_PATH}/models/checkpoints/gonzalomoXLFluxPony_v60newPhotoXLDMD.safetensors"; \
    test -s "${COMFYUI_PATH}/models/loras/Realism Lora By Stable Yogi_V3_Lite.safetensors"; \
    test -s "${COMFYUI_PATH}/models/upscale_models/4x-UltraSharp.pth"

# Проверяем размеры файлов.
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

# Проверяем исправленный workflow.
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

missing_types = required_types - node_types

if missing_types:
    raise RuntimeError(
        f"В workflow отсутствуют ноды: {sorted(missing_types)}"
    )

empty_latents = [
    node
    for node in workflow.get("nodes", [])
    if node.get("type") == "EmptyLatentImage"
]

for node in empty_latents:
    values = node.get("widgets_values", [])

    if len(values) < 2:
        raise RuntimeError("У EmptyLatentImage отсутствует разрешение")

    if values[0] != 896 or values[1] != 1536:
        raise RuntimeError(
            f"Неправильное разрешение EmptyLatentImage: {values}"
        )

print("Workflow validation passed")
PY

# Проверяем, что во всех workflow-папках остался только один JSON.
RUN set -eux; \
    find "${COMFYUI_PATH}" \
        -type f \
        -path "*/workflows/*.json" \
        -print; \
    WORKFLOW_COUNT="$(find "${COMFYUI_PATH}" \
        -type f \
        -path "*/workflows/*.json" | wc -l)"; \
    echo "Total workflow count: ${WORKFLOW_COUNT}"; \
    test "${WORKFLOW_COUNT}" -eq 1; \
    test -f "${COMFYUI_PATH}/user/default/workflows/FLUX_PHOTOSHOP_NSFW.json"
