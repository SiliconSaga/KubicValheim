#!/usr/bin/env bash
# Render a data-driven Valheim instance overlay (kills the valheim1/2/3 copy-paste).
# Usage: start-server.sh <name> [gamePort] [world]
#   <name>     instance id -> namespace valheim-<name> + display name
#   [gamePort] UDP node port for the game (default 32456; 30000-32766; query = +1)
#   [world]    Valheim world/save name (default: capitalized <name>)
# Re-runnable: regenerates kustomize/overlays/<name>/ from the same data shape a
# future Backstage scaffolder will emit. Validates, then optionally applies.
set -euo pipefail

NAME="${1:?usage: start-server.sh <name> [gamePort] [world]}"
GAME_PORT="${2:-32456}"
WORLD="${3:-$(printf '%s' "${NAME^}")}"
QUERY_PORT=$((GAME_PORT + 1))

if (( GAME_PORT < 30000 || GAME_PORT > 32766 )); then
  echo "ERROR: gamePort must be 30000-32766 so the query port (+1) stays in NodePort range." >&2
  exit 1
fi

if [[ ! "$NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <name> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
if (( ${#NAME} > 55 )); then
  echo "ERROR: <name> must be <=55 chars so the namespace valheim-<name> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/kustomize/overlays/$NAME"
mkdir -p "$OVERLAY"

cat > "$OVERLAY/instance-patch.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valheim
spec:
  template:
    spec:
      containers:
        - name: valheim-server
          env:
            - name: NAME
              value: Kubic${NAME^}
            - name: WORLD
              value: ${WORLD}
YAML

cat > "$OVERLAY/secret.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: valheim-secrets
type: Opaque
stringData:
  # Set a real password locally before applying. Do NOT commit it.
  serverPass: CHANGEME
YAML

cat > "$OVERLAY/namespace.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: valheim-${NAME}
YAML

cat > "$OVERLAY/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: valheim-${NAME}

resources:
  - namespace.yaml
  - ../../base
  - secret.yaml

patches:
  - path: instance-patch.yaml
  - target:
      kind: Service
      name: valheim
    patch: |-
      - op: replace
        path: /spec/ports/0/nodePort
        value: ${GAME_PORT}
      - op: replace
        path: /spec/ports/1/nodePort
        value: ${QUERY_PORT}
YAML

echo "Rendered overlay: kustomize/overlays/${NAME} (ns valheim-${NAME}, ports ${GAME_PORT}/${QUERY_PORT}, world ${WORLD})"
kubectl kustomize "$OVERLAY" >/dev/null && echo "kustomize build OK"

if [[ "${APPLY:-0}" == "1" ]]; then
  kubectl apply -k "$OVERLAY"
else
  echo "Dry render only. Set APPLY=1 to 'kubectl apply -k kustomize/overlays/${NAME}'."
fi
