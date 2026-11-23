#!/usr/bin/env bash
# Run once on your own trusted Mac. Never commit a private keystore/password.
set -euo pipefail
umask 077
REPO="popowk/SIM-AI-Assistant"
ALIAS="simai-companion"
KEYDIR="$HOME/Library/Application Support/SIM-AI-Assistant/signing"
KEYSTORE="$KEYDIR/companion-stable.p12"
for bin in keytool gh base64; do
  command -v "$bin" >/dev/null || { echo "缺少工具: $bin"; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "请先在自己的 Mac 执行 gh auth login"; exit 1; }
gh repo view "$REPO" >/dev/null 2>&1 || { echo "无法访问仓库: $REPO"; exit 1; }
echo "准备配置 APK 固定签名。证书将保存在: $KEYSTORE"
echo "重要：旧 APK 若由不同证书签名，仍不能直接无损覆盖。"
[[ -e "$KEYSTORE" ]] && echo "发现旧证书，将复用，不会覆盖。" || echo "未发现证书，将新建并请你离线备份。"
read -r -p "输入 YES 继续: " confirm
[[ "$confirm" == "YES" ]] || exit 1
printf '请输入签名密码（至少16字符，不回显，必须用密码管理器备份）：'
IFS= read -r -s password
echo
[[ ${#password} -ge 16 ]] || { echo "密码长度不足"; exit 1; }
export SIMAI_SIGN_PASS="$password"
unset password
tmp=""
cleanup() { [[ -z "$tmp" ]] || rm -f "$tmp"; unset SIMAI_SIGN_PASS; }
trap cleanup EXIT
mkdir -p "$KEYDIR"
chmod 700 "$KEYDIR"
if [[ ! -e "$KEYSTORE" ]]; then
  tmp="$KEYSTORE.tmp.$$"
  keytool -genkeypair -keystore "$tmp" -storetype PKCS12 \
    -alias "$ALIAS" -keyalg RSA -keysize 3072 -validity 36500 \
    -dname "CN=SIM AI Companion, O=Personal Installation" \
    -storepass:env SIMAI_SIGN_PASS -keypass:env SIMAI_SIGN_PASS -noprompt >/dev/null
  chmod 600 "$tmp"
  mv "$tmp" "$KEYSTORE"
  tmp=""
fi
keytool -list -keystore "$KEYSTORE" -storetype PKCS12 -alias "$ALIAS" \
  -storepass:env SIMAI_SIGN_PASS >/dev/null 2>&1 ||
  { echo "证书与密码不匹配；没有上传到 GitHub"; exit 1; }
echo "验证成功。正在经 GitHub CLI 标准输入设置加密 Actions Secrets……"
base64 < "$KEYSTORE" | tr -d '\n' | gh secret set SIMAI_ANDROID_KEYSTORE_B64 --repo "$REPO"
printf '%s' "$SIMAI_SIGN_PASS" | gh secret set SIMAI_ANDROID_KEYSTORE_PASSWORD --repo "$REPO"
printf '%s' "$ALIAS" | gh secret set SIMAI_ANDROID_KEY_ALIAS --repo "$REPO"
printf '%s' "$SIMAI_SIGN_PASS" | gh secret set SIMAI_ANDROID_KEY_PASSWORD --repo "$REPO"
echo "四项 Secrets 已写入 GitHub。请立刻离线备份证书与密码。"
echo "证书位置：$KEYSTORE"
keytool -list -v -keystore "$KEYSTORE" -storetype PKCS12 \
  -alias "$ALIAS" -storepass:env SIMAI_SIGN_PASS 2>/dev/null |
  grep -m 1 -i 'SHA256:' || true
echo "请手动运行 GitHub Actions，新版应标识 STABLE_SECRET_SIGNING。"
echo "旧 APK 证书若不同，须单独确认一次迁移；脚本不会卸载旧手机应用。"
