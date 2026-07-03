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

# --- validate <name> first (it seeds the namespace, overlay dir, and default world) ---
if [[ ! "$NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <name> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
# Reserved names would overwrite the committed curated overlays.
case "$NAME" in
  plain|gitops|base)
    echo "ERROR: <name> '$NAME' is a reserved overlay name — pick another (it would overwrite the committed overlay)." >&2
    exit 1
    ;;
esac
if (( ${#NAME} > 55 )); then
  echo "ERROR: <name> must be <=55 chars so the namespace valheim-<name> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi

# Capitalize the first character for the display name / default world. ${NAME^} is a
# Bash 4+ feature and macOS ships Bash 3.2, so do it the POSIX way.
NAME_CAP="$(printf '%s' "$NAME" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$NAME" | cut -c2-)"

WORLD="${3:-$NAME_CAP}"
# Restrict the world name to a safe allowlist: it flows into an (unquoted) heredoc,
# so `$`, backticks, quotes, or newlines could inject shell/YAML. Letters, digits,
# spaces, hyphens, and underscores cover real Valheim world names.
world_re='^[A-Za-z0-9 _-]+$'
if [[ ! "$WORLD" =~ $world_re ]]; then
  echo "ERROR: world name may only contain letters, digits, spaces, hyphens, and underscores." >&2
  exit 1
fi

# Validate gamePort is an integer BEFORE the arithmetic below, so a non-numeric
# input yields the friendly message instead of an opaque $(( )) error under set -e.
if [[ ! "$GAME_PORT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: gamePort must be an integer (30000-32766)." >&2
  exit 1
fi
if (( GAME_PORT < 30000 || GAME_PORT > 32766 )); then
  echo "ERROR: gamePort must be 30000-32766 so the query port (+1) stays in NodePort range." >&2
  exit 1
fi
QUERY_PORT=$((GAME_PORT + 1))

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
              value: "Kubic${NAME_CAP}"
            - name: WORLD
              value: "${WORLD}"
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
  # JSON6902 by index, GUARDED with test ops asserting the port names, so a reorder
  # of base/service.yaml's port list fails the build loudly instead of silently
  # patching the wrong port. (Strategic-merge on Service ports doesn't reliably
  # match by the port field alone, so the guarded-index form is used instead.)
  - target:
      kind: Service
      name: valheim
    patch: |-
      - op: test
        path: /spec/ports/0/name
        value: game
      - op: replace
        path: /spec/ports/0/nodePort
        value: ${GAME_PORT}
      - op: test
        path: /spec/ports/1/name
        value: query
      - op: replace
        path: /spec/ports/1/nodePort
        value: ${QUERY_PORT}
YAML

echo "Rendered overlay: kustomize/overlays/${NAME} (ns valheim-${NAME}, ports ${GAME_PORT}/${QUERY_PORT}, world ${WORLD})"
# Explicit guard, not `... && echo OK`: under set -e a failed left side of && does
# NOT exit, so a broken build would fall through to the APPLY check silently.
if ! kubectl kustomize "$OVERLAY" >/dev/null; then
  echo "ERROR: kustomize build failed for kustomize/overlays/${NAME}" >&2
  exit 1
fi
echo "kustomize build OK"

if [[ "${APPLY:-0}" == "1" ]]; then
  kubectl apply -k "$OVERLAY"
else
  echo "Dry render only. Set APPLY=1 to 'kubectl apply -k kustomize/overlays/${NAME}'."
fi
