#!/bin/bash
# 接管 Readit：push 代码 → 检查线上 → 本地 build 安装 → 写入网关/模型/TTS 配置
# 用法：BASE_URL=https://你的网关 ./takeover.sh     （Key 会交互式输入，不落盘到脚本）
set -euo pipefail
cd "$(dirname "$0")"
BUNDLE=local.bireader.app
CHAT_MODEL="${CHAT_MODEL:-claude-haiku-5-5}"
TTS_MODEL="${TTS_MODEL:-gemini-3.8-tts}"

echo "== 1. Git push =="
git status -sb
git remote -v
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "chore: takeover sync $(date +%F)"
fi
git push -u origin "$(git rev-parse --abbrev-ref HEAD)"

echo "== 2. 线上检查 https://readit.novarock.io =="
curl -sS -o /dev/null -w "首页 HTTP %{http_code}  %{time_total}s\n" https://readit.novarock.io/ || true
curl -sS -o /dev/null -w "healthz HTTP %{http_code}\n" https://readit.novarock.io/healthz || true
echo | openssl s_client -connect readit.novarock.io:443 -servername readit.novarock.io 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null || echo "证书检查失败"
ssh -o ConnectTimeout=5 "${HOST:-novarocks}" \
  "kubectl -n readit get deploy,pods,ingress -o wide" 2>/dev/null || echo "（无法 ssh 到 k8s 主机，跳过集群检查）"

echo "== 3. 本地 build + 安装 =="
osascript -e 'quit app "Readit"' 2>/dev/null || true
./build_app.sh

echo "== 4. 网关 / 模型 / TTS 配置 =="
: "${BASE_URL:?请先设置 BASE_URL，例如 BASE_URL=https://gateway.example.com ./takeover.sh}"
read -rsp "网关 API Key: " API_KEY; echo
defaults write $BUNDLE baseURL -string "$BASE_URL"
defaults write $BUNDLE apiKey  -string "$API_KEY"
defaults write $BUNDLE model   -string "$CHAT_MODEL"
for role in translate chat; do
  defaults write $BUNDLE "model.$role" -string "$CHAT_MODEL"
  defaults write $BUNDLE "style.$role" -string anthropic
done
defaults write $BUNDLE model.tts -string "$TTS_MODEL"

echo "-- 网关上的模型列表（确认名称存在）:"
curl -sS "${BASE_URL%/}/v1/models" -H "Authorization: Bearer $API_KEY" -H "x-api-key: $API_KEY" \
  | grep -oE '"id" *: *"[^"]+"' | grep -iE 'haiku|tts' || echo "（未匹配到 haiku/tts，请检查模型名）"

echo "-- 测试 Anthropic 协议调用:"
curl -sS "${BASE_URL%/}/v1/messages" -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" -H "anthropic-version: 2023-06-01" \
  -d "{\"model\":\"$CHAT_MODEL\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" | head -c 400; echo
unset API_KEY
open /Applications/Readit.app
echo "完成。"
