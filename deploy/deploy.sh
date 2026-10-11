#!/usr/bin/env bash
# Re-runnable deploy of the Readit landing site to novarocks k8s.
set -euo pipefail
HOST="${HOST:-novarocks}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DIR="readit-landing-build"
TAG="readit-landing:$(date +%Y%m%d-%H%M%S)"

echo ">> rsync to $HOST:~/$REMOTE_DIR"
ssh "$HOST" "mkdir -p ~/$REMOTE_DIR"
rsync -az --delete "$ROOT/landing/" "$HOST:~/$REMOTE_DIR/landing/"
rsync -az --delete "$ROOT/deploy/" "$HOST:~/$REMOTE_DIR/deploy/"

echo ">> build + import $TAG"
ssh "$HOST" bash -s <<REMOTE
set -euo pipefail
cd ~/$REMOTE_DIR
docker build -f deploy/Dockerfile -t "$TAG" .
docker save "$TAG" | sudo ctr -n k8s.io images import -
kubectl apply -f deploy/k8s.yaml
kubectl -n readit set image deployment/landing web="docker.io/library/$TAG"
kubectl -n readit rollout status deployment/landing --timeout=180s
REMOTE
echo ">> deployed $TAG -> https://readit.novarock.io"
