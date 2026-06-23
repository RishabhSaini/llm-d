# Disaggregated Omni-Modal Serving

## Overview

This guide deploys Qwen3-TTS with each pipeline stage running as an independent pod, scheduled by the EPP with stage-specific scoring profiles. The talker (autoregressive codec generation) and code2wav (audio decoder) scale independently.

A coordinator sequences the stages via HTTP — it forwards the original request to the talker, pipes the talker's codec token output to code2wav, and proxies the audio back to the client. The EPP uses a `header-routed-profile-handler` to select the scheduling profile based on the `EPP-Phase` request header.

### Architecture

```
Client → Coordinator → Envoy/EPP → Talker Pod (codec tokens)
                     → Envoy/EPP → Code2wav Pod (audio output)
                   ← audio response
```

### Configuration

| Parameter | Value |
|-----------|-------|
| Model | Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice |
| Stages | 2 (talker + code2wav) |
| Talker GPUs | 1 |
| Code2wav GPUs | 1 |

### Custom Images

This guide uses custom images with stage isolation support:

| Component | Image |
|-----------|-------|
| vllm-omni | `quay.io/rh_ee_rsaini/llm-d-omni-cuda:latest` |
| Coordinator | `quay.io/rh_ee_rsaini/llm-d-coordinator:latest` |
| Router EPP | `quay.io/rh_ee_rsaini/llm-d-router-epp:latest` |

## Prerequisites

- Have the [proper client tools installed on your local system](../../helpers/client-setup/README.md) to use this guide.
- Checkout llm-d repo:

  ```bash
    export branch="main"
    git clone https://github.com/llm-d/llm-d.git && cd llm-d && git checkout ${branch}
  ```

- Set the following environment variables:

  ```bash
    export REPO_ROOT=$(realpath $(git rev-parse --show-toplevel))
    source ${REPO_ROOT}/guides/env.sh
    export GUIDE_NAME="disagg-omni-serving"
    export NAMESPACE=llm-d-disagg-omni
  ```

- Install the Gateway API Inference Extension CRDs:

  ```bash
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml
  ```

- Create a target namespace:

  ```bash
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
  ```

- [Create the `llm-d-hf-token` secret](../../helpers/hf-token.md):
<!-- llm-d-cicd:skip start -->
  ```bash
  export HF_TOKEN=<your HuggingFace token>
  kubectl create secret generic llm-d-hf-token \
    --from-literal="HF_TOKEN=${HF_TOKEN}" \
    --namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  ```
<!-- llm-d-cicd:skip end -->

## Build Custom Images (Optional)

If you need to rebuild the images:

```bash
# vllm-omni with --standalone support
cd ${REPO_ROOT}/guides/${GUIDE_NAME}/docker
docker build -f Dockerfile.omni \
    --build-arg VLLM_OMNI_REPO=https://github.com/RishabhSaini/vllm-omni.git \
    --build-arg VLLM_OMNI_BRANCH=standalone-stage-mode \
    -t quay.io/rh_ee_rsaini/llm-d-omni-cuda:latest .
docker push quay.io/rh_ee_rsaini/llm-d-omni-cuda:latest
```

## Installation Instructions

### 1. Deploy the llm-d Router

```bash
helm install ${GUIDE_NAME} \
    ${ROUTER_STANDALONE_CHART} \
    -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
    -f ${REPO_ROOT}/guides/${GUIDE_NAME}/router/disagg-omni.values.yaml \
    -n ${NAMESPACE} --version ${ROUTER_CHART_VERSION}
```

### 2. Deploy the Model Servers

```bash
kubectl apply -n ${NAMESPACE} -f ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/gpu/vllm-omni/base/patch-talker.yaml
kubectl apply -n ${NAMESPACE} -f ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/gpu/vllm-omni/base/patch-code2wav.yaml
```

### 3. Deploy the Coordinator

```bash
kubectl apply -n ${NAMESPACE} -f ${REPO_ROOT}/guides/${GUIDE_NAME}/coordinator/coordinator.yaml
```

### 4. Wait for readiness

```bash
kubectl get pods -n ${NAMESPACE} -w -l llm-d.ai/guide=${GUIDE_NAME}
```

Initial startup takes 5-10 minutes per stage (weight loading, torch.compile, CUDA graph capture).

## Verification

### 1. Get the Coordinator IP

```bash
export IP=$(kubectl get service coordinator -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
```

### 2. Send Test Requests

Open a temporary interactive shell inside the cluster:

```bash
kubectl run curl-debug --rm -it \
    --image=cfmanteiga/alpine-bash-curl-jq \
    --namespace="$NAMESPACE" \
    --env="IP=$IP" \
    -- /bin/bash
```

Generate speech:

```bash
curl -s -X POST http://${IP}:8080/v1/audio/speech \
    -H "Content-Type: application/json" \
    -d '{
        "model": "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
        "input": "Hello from disaggregated TTS serving.",
        "voice": "vivian"
    }' --output test.wav
```

### 3. Scale Stages Independently

```bash
# Scale talker to handle more AR generation load
kubectl scale deployment talker -n ${NAMESPACE} --replicas=3

# Code2wav stays at 1 (fast single-pass decoder)
kubectl get deployment code2wav -n ${NAMESPACE}
```

## Cleanup

```bash
kubectl delete -n ${NAMESPACE} -f ${REPO_ROOT}/guides/${GUIDE_NAME}/coordinator/coordinator.yaml
kubectl delete -n ${NAMESPACE} -f ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/gpu/vllm-omni/base/
helm uninstall ${GUIDE_NAME} -n ${NAMESPACE}
kubectl delete namespace ${NAMESPACE}
```
