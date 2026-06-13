#!/usr/bin/env bash
#
# 造一张自签 Code Signing 证书,供 Ghostty.app 与 XGhostty.app 共用签名。
#
# 为什么不用 ad-hoc `codesign --sign -`:ad-hoc 的 designated requirement 是
# 逐次构建变化的 cdhash,每次重建后 Keychain ACL 失配 → 读密码弹授权框,正好
# 砸在“要 ssh 进生产”那一刻。固定证书的 DR 基于证书指纹、跨构建稳定 →
# 授权一次永久有效,同时根治现有 session-sharing token 的 churn。
#
# 用法:  bash contrib/xghostty/setup-dev-cert.sh      （幂等,已存在则跳过）
# 之后:  codesign 改用  --sign "Ghostty Dev Cert"  替代  --sign -
#
set -euo pipefail

CERT_CN="Ghostty Dev Cert"
DAYS=3650
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_CN"; then
  echo "✅ 已存在 \"$CERT_CN\",无需重复创建:"
  security find-identity -v -p codesigning | grep "$CERT_CN"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1) 私钥 + 自签证书(带 codeSigning 扩展用途)
cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $CERT_CN
[ext]
basicConstraints = critical,CA:FALSE
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days "$DAYS" -config "$TMP/cert.conf"
# macOS `security` 导入 p12 有两个坑(已用临时钥匙串实测):
#   ① 空密码 → PKCS#12 MAC 派生有歧义,security 一律报 "MAC verification failed";
#      解法:用一个非空的 p12 中转密码(导入钥匙串后即弃,不是私钥的最终保护)。
#   ② OpenSSL 3.x 默认 AES-256/SHA-256 → security 认不了;
#      解法:-legacy(3DES/RC2)+ -macalg sha1。LibreSSL 无这俩选项且默认就兼容,故按支持自动加。
P12PW="xghostty-p12-transit"
P12_OPTS=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
  P12_OPTS="-legacy -macalg sha1"
fi
openssl pkcs12 -export $P12_OPTS -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12PW"

# 2) 导入 login 钥匙串,并把 codesign 加进私钥 ACL 白名单
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12PW" -T /usr/bin/codesign

# 3) 设为受信任的代码签名根(仅 codeSign 策略)——可能弹一次授权框,点允许
security add-trusted-cert -r trustRoot -p codeSign "$TMP/cert.pem" || true

# 4) 放开 partition list,让 codesign 无提示取私钥(需 login 钥匙串密码)
echo "🔑 输入你的 login 钥匙串密码(授权 codesign 无提示访问私钥,不回显):"
read -rs KCPW
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KEYCHAIN" >/dev/null 2>&1 || true
unset KCPW

echo ""
if security find-identity -v -p codesigning | grep -q "$CERT_CN"; then
  echo "✅ 完成。可用签名身份:"
  security find-identity -v -p codesigning | grep "$CERT_CN"
  echo ""
  echo "下一步:codesign 改用  --sign \"$CERT_CN\"  （Ghostty.app 与 XGhostty.app 共用这张）"
else
  echo "⚠️  find-identity 未列出该身份——命令行自签偶尔不被识别。"
  echo "    最稳的回退:钥匙串访问 → 证书助理 → 创建证书"
  echo "    （名称 \"$CERT_CN\" / 身份类型 自签名根 / 证书类型 代码签名 / 有效期拉长）"
  exit 1
fi
