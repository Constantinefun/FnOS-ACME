#!/bin/bash
set -e

# 日志目录和函数提前定义，保证全局可用
mkdir -p ./log
FIRST_LOG="./log/first_run.log"
RUN_LOG="./log/cer_update.log"
# $1=消息, $2=可选日志文件（不传默认 RUN_LOG）
log_message() {
  local msg="$1"
  local file="${2:-$RUN_LOG}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" >> "$file"
}

# 脚本所在根目录（用于 ACME_PREFIX 默认值）
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

CONFIG_FILE="./config.ini"

# --- 第一次运行：交互生成 config.ini（API + 运行参数） ---
if [ ! -f "$CONFIG_FILE" ]; then
  echo "=== 首次运行，请输入配置 ==="

  # 1) 选择 ACME CA 服务器（必须在注册前设置）
  echo "选择 ACME CA 服务器："
  echo "  1) letsencrypt            (https://acme-v02.api.letsencrypt.org/directory)"
  echo "  2) letsencrypt_test       (https://acme-staging-v02.api.letsencrypt.org/directory)"
  echo "  3) zerossl                (https://acme.zerossl.com/v2/DV90)"
  echo "  4) buypass                (https://api.buypass.com/acme/directory)"
  echo "  5) buypass_test           (https://api.test4.buypass.no/acme/directory)"
  echo "  6) sslcom                 (https://acme.ssl.com/sslcom-dv-rsa 或 sslcom-dv-ecc)"
  echo "  7) google                 (https://dv.acme-v02.api.pki.goog/directory)"
  echo "  8) googletest             (https://dv.acme-v02.test-api.pki.goog/directory)"
  echo "  9) custom                 (输入自定义短名称或完整 URL)"
  read -p "请输入 [1-9]: " caopt
  case "$caopt" in
    2) CA_SERVER="letsencrypt_test" ;;
    3) CA_SERVER="zerossl" ;;
    4) CA_SERVER="buypass" ;;
    5) CA_SERVER="buypass_test" ;;
    6) CA_SERVER="sslcom" ;;
    7) CA_SERVER="google" ;;
    8) CA_SERVER="googletest" ;;
    9)
      read -p "请输入自定义 ACME 短名称或完整 URL: " CA_SERVER
      ;;
    *) CA_SERVER="letsencrypt" ;;  # 默认
  esac
  echo "→ 已选择 CA: $CA_SERVER"

  # 启动容器后立即在里面设置默认 CA
  echo "=== 启动 acme.sh 容器中 ==="
  # 启动并检查 acme.sh 容器
  log_message "启动 Docker 容器 acme.sh..." "$FIRST_LOG"
  docker start acme.sh
  log_message "等待容器启动..." "$FIRST_LOG"
  sleep 10
  docker ps | grep acme.sh > /dev/null
  if [ $? -ne 0 ]; then
    log_message "容器启动失败，请检查容器状态。" "$FIRST_LOG"
    echo "acme.sh 容器启动失败，无法注册账号。"
    exit 1
  fi
  echo "=== acme.sh 容器启动成功 ==="
  echo "=== 配置 CA 中 ==="
  log_message "设置容器默认 CA 为 $CA_SERVER" "$FIRST_LOG"
  docker exec acme.sh /root/.acme.sh/acme.sh --set-default-ca --server "$CA_SERVER"
  echo "=== 配置 CA 完成 ==="

  # 2) 注册邮箱
  read -p "请输入注册邮箱地址 (用于 acme.sh 注册): " REG_EMAIL 
  echo "=== 注册 acme.sh 账户中  ==="
  log_message "在容器内注册账户 $REG_EMAIL" "$FIRST_LOG"
  docker exec acme.sh /root/.acme.sh/acme.sh --register-account -m "$REG_EMAIL"

  # 2) DNS API 服务商（支持多参数）
  echo "选择 DNS API 服务商："
  echo "  1) 腾讯云（2 参数）"
  echo "  2) 阿里云（2 参数）"
  echo "  3) Cloudflare（2 参数）"
  echo "  4) 其他（自定义参数个数）"
  read -p "请输入 [1-4]: " opt

  case "$opt" in
    1)
      PROVIDER="Tencent"; DNS_PROVIDER="dns_tencent"
      PARAM_NAMES=( "Tencent_SecretId" "Tencent_SecretKey" )
      ;;
    2)
      PROVIDER="Ali"; DNS_PROVIDER="dns_ali"
      PARAM_NAMES=( "Ali_Key" "Ali_Secret" )
      ;;
    3)
      PROVIDER="Cloudflare"; DNS_PROVIDER="dns_cf"
      PARAM_NAMES=( "CF_Key" "CF_Email" )
      ;;
    4)
      PROVIDER="Other"
      read -p "acme.sh --dns 参数 (如 dns_dp): " DNS_PROVIDER
      read -p "该服务商需要几个 API 参数？" count
      PARAM_NAMES=()
      for ((i=1; i<=count; i++)); do
        read -p "第 $i 个环境变量名: " name
        PARAM_NAMES+=( "$name" )
      done
      ;;
    *)
      echo "无效，默认腾讯云"
      PROVIDER="Tencent"; DNS_PROVIDER="dns_tencent"
      PARAM_NAMES=( "Tencent_SecretId" "Tencent_SecretKey" )
      ;;
  esac

  # 依次读取所有参数值
  declare -A PARAM_VALUES
  for name in "${PARAM_NAMES[@]}"; do
    read -p "请输入 $name: " val
    PARAM_VALUES[$name]="$val"
  done

  # 2) 本次运行参数
  echo "脚本当前所在目录：$SCRIPT_DIR"
  read -p "请输入 ACME 目录前缀（默认脚本目录下的 acme.sh 子目录；除非你很清楚，否则请直接回车保持默认）: " ACME_PREFIX
  ACME_PREFIX=${ACME_PREFIX:-"$SCRIPT_DIR/"}

  read -p "请输入需要更新的系统域名，逗号分隔 (DOMAINS1): " line1
  DOMAINS1_RAW="$line1"

  read -p "请输入需要生成 .pfx 证书的域名，逗号分隔（留空则不生成 .pfx）: " line2
  if [ -z "$line2" ]; then
    DOMAINS2_RAW=""
    PASSWORD=""
    PFX_DIR=""
  else
    DOMAINS2_RAW="$line2"
    read -p ".pfx 密码 (默认 12345678a): " PASSWORD
    PASSWORD=${PASSWORD:-12345678a}
    read -p ".pfx 目标目录 (留空不复制): " PFX_DIR
  fi

  # —— 统一写入 config.ini ——  
cat >"$CONFIG_FILE" <<EOF
CA_SERVER=$CA_SERVER
REG_EMAIL=$REG_EMAIL

# API 配置
PROVIDER=$PROVIDER
DNS_PROVIDER=$DNS_PROVIDER
PARAM_NAMES=$(IFS=','; echo "${PARAM_NAMES[*]}")
EOF

# 逐行追加每个 name=value
for name in "${PARAM_NAMES[@]}"; do
  echo "${name}=${PARAM_VALUES[$name]}" >>"$CONFIG_FILE"
done
 
          
cat >>"$CONFIG_FILE" <<EOF
# 运行参数
ACME_PREFIX=$ACME_PREFIX
DOMAINS1_RAW=$DOMAINS1_RAW
DOMAINS2_RAW=$DOMAINS2_RAW
PASSWORD=$PASSWORD
PFX_DIR=$PFX_DIR

# 自动执行间隔（格式 x年x月x天x时x分）
# 默认每月1日0时0分执行
SCHEDULE_INTERVAL=0年1月1天0时0分

# 测试模式：1=跳过有效期检查，0=实际检查
TEST_MODE=0
EOF
  echo "=== 停止 acme.sh 容器中 ==="
  # 停止 Docker 容器
  docker stop acme.sh

  echo "acme.sh 容器已停止。"
          
  # —— 可选：启用自动执行(cron) ——  
  read -p "是否需要启用自动执行(cron)？[Y/n]: " enable_cron
  if [[ "$enable_cron" =~ ^(Y|y|YES|yes|)$ ]]; then
    SCRIPT_PATH="$(readlink -f "$0")"
    sched="$SCHEDULE_INTERVAL"
    IFS='年月天时分' read -r Y M D h m _ <<< "$sched"
    total_months=$(( Y*12 + M ))
    day_field=$(( D>0 ? D : 1 ))
    if (( total_months>0 )); then
      month_field="*/$total_months"
    else
      month_field="*"
    fi
    cron_line="$m $h $day_field $month_field * $SCRIPT_PATH"

    # 先读取现有 crontab
    existing=$(crontab -l 2>/dev/null || true)
    # 如果已存在旧条目，先过滤掉
    if echo "$existing" | grep -Fq "$SCRIPT_PATH"; then
      echo "$existing" | grep -vF "$SCRIPT_PATH" | crontab -
    fi
    # 再添加新条目
    ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab -

    echo "✅ 已启用自动执行，计划为：$cron_line"
  else
    echo "⚠️ 跳过自动执行配置，脚本仅支持手动触发。"
  fi
  echo "配置已保存到 $CONFIG_FILE，后续直接运行即可。"
  exit 0
fi

# --- 后续运行：加载 config.ini ---
source "$CONFIG_FILE"

# 加载测试模式
TEST_MODE=${TEST_MODE:-0}
if [ "$TEST_MODE" -eq 1 ]; then
  echo "已启用测试模式：跳过证书有效期检查，所有域名都会更新。"
else
  echo "生产模式：将验证证书有效期，只更新剩余天数 ≤7 天的证书。"
fi

# --- 确保 CA 和 账户 设置正确 ---
echo "=== 确认 CA 和 账户 ==="
# 读取配置
CA_SERVER=${CA_SERVER:-letsencrypt}
REG_EMAIL=${REG_EMAIL:?请先在 config.ini 中设置 REG_EMAIL}
# 计算 ACME_DIR，避免双重 "acme.sh"
if [[ "$(basename "${ACME_PREFIX%/}")" == "acme.sh" ]]; then
  # 用户已经把 acme.sh 放到前缀里
  ACME_DIR="${ACME_PREFIX%/}/"
else
  # 按旧逻辑拼一个子目录 acme.sh
  ACME_DIR="${ACME_PREFIX%/}/acme.sh/"
fi

# 启动 Docker 容器
echo "=== 启动 acme.sh 容器中 ==="
log_message "启动 Docker 容器 acme.sh..."
docker start acme.sh

# 等待容器启动并检查
log_message "等待容器启动..."
sleep 10
docker ps | grep acme.sh > /dev/null
if [ $? -ne 0 ]; then
    log_message "容器启动失败，请检查容器状态。" >&2
    exit 1
fi
echo "=== acme.sh 容器启动成功 ==="

# --- 在“确定 CA 和账户”那块 ---
ACME_DATA_DIR="${ACME_DIR%/}"   # 与容器里挂载的根目录保持一致

# 1) 重设默认 CA
docker exec acme.sh /root/.acme.sh/acme.sh --set-default-ca --server "$CA_SERVER"

# 2) 根据 CA_SERVER 选项，拼出 account.json 真实路径的中间段
case "$CA_SERVER" in
  letsencrypt)
    # letsencrypt 下实际是 ca/acme-v02.api.letsencrypt.org/directory/account.json
    DIR_NAME="acme-v02.api.letsencrypt.org/directory"
    ;;
  letsencrypt_test)
    DIR_NAME="acme-staging-v02.api.letsencrypt.org/directory"
    ;;
  zerossl)
    # zerossl 下是 ca/acme.zerossl.com/v2/DV90/account.json
    DIR_NAME="acme.zerossl.com/v2/DV90"
    ;;
  buypass)
    DIR_NAME="api.buypass.com/acme/directory"
    ;;
  buypass_test)
    DIR_NAME="api.test4.buypass.no/acme/directory"
    ;;
  sslcom)
    DIR_NAME="acme.ssl.com/sslcom-dv-rsa"
    ;;
  google)
    DIR_NAME="dv.acme-v02.api.pki.goog/directory"
    ;;
  googletest)
    DIR_NAME="dv.acme-v02.test-api.pki.goog/directory"
    ;;
  *)
    # 自定义 URL，把 https:// 和 “/” 换成 “.”
    DIR_NAME=$(echo "$CA_SERVER" \
      | sed -E 's#https?://##; s#/#.#g; s/\.$//')
    ;;
esac

# 3) 直接拼 account.json 的完整路径
JSON_PATH="$ACME_DATA_DIR/ca/$DIR_NAME/account.json"

# 4) 如果存在，就从 JSON 中读取 contact[0]
if [ -f "$JSON_PATH" ]; then
  if command -v jq >/dev/null 2>&1; then
    CURRENT_EMAIL=$(jq -r '.contact[0] | sub("^mailto:"; "")' "$JSON_PATH")
  else
    CURRENT_EMAIL=$(grep -Po '"contact"\s*:\s*\[\s*"\Kmailto:[^"]+' "$JSON_PATH" \
                    | sed 's/^mailto://')
  fi
else
  CURRENT_EMAIL=""
fi

# 5) 比对并（必要时）重新注册
if [ "$CURRENT_EMAIL" != "$REG_EMAIL" ]; then
  echo "→ 账户 $REG_EMAIL 未注册或不匹配（当前: '$CURRENT_EMAIL'），正在注册..."
  docker exec acme.sh /root/.acme.sh/acme.sh --register-account -m "$REG_EMAIL"
  sleep 2
  echo "→ 注册完成，新的 email："
  [ -f "$JSON_PATH" ] && grep -Po '"contact"\s*:\s*\[\s*"\Kmailto:[^"]+' "$JSON_PATH" \
                      | sed 's/^mailto://' \
    || echo "!! account.json 里仍未找到邮箱"
else
  echo "→ 账户 $REG_EMAIL 已注册"
fi

echo "=== CA 和 账户确认完毕 ==="

# 加载自动执行间隔
SCHEDULE_INTERVAL=${SCHEDULE_INTERVAL:-"0年1月1天0时0分"}

# 解析 SCHEDULE_INTERVAL
# 拆成：年、月、天、时、分
IFS='年月天时分' read -r Y M D h m _ <<< "$SCHEDULE_INTERVAL"

# 计算 cron 字段
# 月份周期：Y 年 + M 月 => total_months
total_months=$(( Y*12 + M ))
if (( total_months>0 )); then
  month_field="*/$total_months"
else
  month_field="*"
fi
# 日：如果 D>0 则用 D，否则用 1
day_field=$(( D>0 ? D : 1 ))
hour_field=$h
min_field=$m

# 脚本绝对路径
SCRIPT_PATH="$(readlink -f "$0")"

# 构造目标 cron 行
# 格式：<分> <时> <日> <月> * <脚本>
desired_cron="$min_field $hour_field $day_field $month_field * $SCRIPT_PATH"

# 读取现有 crontab
existing_cron=$(crontab -l 2>/dev/null || true)

# 如果用户关闭自动执行（0年0月0天0时0分），则删除所有本脚本条目
if [[ "$Y" -eq 0 && "$M" -eq 0 && "$D" -eq 0 && "$h" -eq 0 && "$m" -eq 0 ]]; then
  # **先检测再删除**
  if echo "$existing_cron" | grep -Fq "$SCRIPT_PATH"; then
    # 只在存在时才执行过滤并写回
    echo "$existing_cron" | grep -vF "$SCRIPT_PATH" | crontab -
    echo "已移除自动执行配置。"
  else
    echo "无自动执行配置，无需删除。"
  fi

# 否则，启用或更新自动执行
else
  # 如果已有条目，但与 desired_cron 不同，先删除旧条目
  if echo "$existing_cron" | grep -Fq "$SCRIPT_PATH"; then
    if ! echo "$existing_cron" | grep -Fq "$desired_cron"; then
      # **也要先确认旧条目存在再删除**
      echo "$existing_cron" | grep -vF "$SCRIPT_PATH" | crontab -
    fi
  fi

  # 最后确保 desired_cron 在 crontab 中
  (
    crontab -l 2>/dev/null || true
  ) | {
    # 再次检测，避免重复添加
    if ! grep -Fq "$desired_cron"; then
      echo "$desired_cron"
    fi
  } | crontab -

  echo "✅ 已设置自动执行：$desired_cron"
fi

read -r PARAM_NAMES_CSV <<< "$PARAM_NAMES"
IFS=',' read -r -a PARAM_NAMES <<< "$PARAM_NAMES_CSV"
for name in "${PARAM_NAMES[@]}"; do
  export "$name"="${!name}"
done
                                     
CONFIG_DIR=$(dirname "$CONFIG_FILE")
LOG_FILE="${CONFIG_DIR}/log/cer_update.log"
mkdir -p "$(dirname "$LOG_FILE")"

echo "使用 DNS 提供商：$PROVIDER (--dns $DNS_PROVIDER)"
echo "ACME 脚本目录：$ACME_DIR"
echo "日志文件：$LOG_FILE"
echo "要更新的域名：$DOMAINS1_RAW"
[ -n "$DOMAINS2_RAW" ] && echo "要生成 .pfx 的域名：$DOMAINS2_RAW"
echo

# 解析域名列表
IFS=',' read -r -a DOMAINS1 <<< "$DOMAINS1_RAW"
if [ -n "$DOMAINS2_RAW" ]; then
  IFS=',' read -r -a DOMAINS2 <<< "$DOMAINS2_RAW"
else
  DOMAINS2=()
fi

# 固定变量
SSL_DIR="/usr/trim/var/trim_connect/ssls"

# 记录日志函数
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_message "证书更新脚本开始执行..."

# 证书有效期检查函数
check_cert_expiry() {
  local CERT_FILE=$1
  echo "检查证书有效期..."

  # 获取证书的有效期
  EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" | sed "s/^.*=\(.*\)$/\1/")
  EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s)
  CURRENT_TIMESTAMP=$(date +%s)

  # 计算证书剩余有效天数
  REMAIN_DAYS=$(( (EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP) / 86400 ))

  echo "证书有效期到: $EXPIRY_DATE"
  echo "剩余有效天数: $REMAIN_DAYS"

  # 如果证书有效期剩余天数大于 7 天，则不进行更新
  if [ $REMAIN_DAYS -gt 7 ]; then
    echo "证书有效期剩余超过7天，不需要更新，跳过该域名."
    return 1  # 证书有效，跳过更新
  fi

  return 0  # 证书即将过期，继续更新
}

# 处理 DOMAINS1 列表
for DOMAIN in "${DOMAINS1[@]}"; do
    DOMAIN_DIR="${ACME_DIR}${DOMAIN}_ecc"               # 域名证书存放目录

    # 判断SSL_DIR/${DOMAIN}是否有文件夹
    if [ -d "${SSL_DIR}/${DOMAIN}" ]; then
        # 如果目录存在，获取第一个文件夹名称
        RANDOM_CONTENT=$(ls -d "${SSL_DIR}/${DOMAIN}/"* | head -n 1 | xargs basename)
        log_message "${DOMAIN} 目录存在，随机内容为：${RANDOM_CONTENT}"
        DOMAIN_SSL_DIR="${SSL_DIR}/${DOMAIN}/${RANDOM_CONTENT}"
    else
        # 如果目录不存在，跳过文件夹读取部分
        log_message "${DOMAIN} 目录不存在，直接进行证书申请，不更新 SSL 文件路径"
        DOMAIN_SSL_DIR=""  # 设置空值，跳过后续的文件拷贝
    fi

    # 证书有效期检查
    if [ "$TEST_MODE" -eq 0 ]; then
      CERT_FILE="${DOMAIN_DIR}/fullchain.pem"
      check_cert_expiry "$CERT_FILE" || continue
    else
      log_message "测试模式：跳过 ${DOMAIN} 的证书有效期检查，强制更新"
    fi

    # 删除指定域名的旧证书文件夹
    log_message "删除 ${DOMAIN} 的旧证书文件夹路径：${DOMAIN_DIR}..."
    rm -rf "${DOMAIN_DIR}"/*

    # 构造所有 API 环境变量
	env_args=()
	for name in "${PARAM_NAMES[@]}"; do
	  env_args+=( "-e" "$name=${!name}" )
	done

	# 申请证书
	docker exec "${env_args[@]}" acme.sh /root/.acme.sh/acme.sh \
      --issue --dns "$DNS_PROVIDER" -d "$DOMAIN" --force

	# 安装证书（含 ca.cer）
	docker exec "${env_args[@]}" acme.sh /root/.acme.sh/acme.sh \
      --install-cert -d "$DOMAIN" \
	  --key-file      "/acme.sh/${DOMAIN}_ecc/privkey.pem" \
	  --fullchain-file "/acme.sh/${DOMAIN}_ecc/fullchain.pem" \
	  --ca-file       "/acme.sh/${DOMAIN}_ecc/ca.cer"

   # 如果存在随机内容目录，则执行拷贝操作
    if [ -n "$DOMAIN_SSL_DIR" ]; then
        mkdir -p "${DOMAIN_SSL_DIR}"

        # 主证书 .crt
        cp -f "${DOMAIN_DIR}/fullchain.pem" "${DOMAIN_SSL_DIR}/${DOMAIN}.crt"
        chmod 0755 "${DOMAIN_SSL_DIR}/${DOMAIN}.crt"
        log_message "拷贝 ${DOMAIN}.crt 文件成功."

        # 私钥 .key
        cp -f "${DOMAIN_DIR}/privkey.pem" "${DOMAIN_SSL_DIR}/${DOMAIN}.key"
        chmod 0755 "${DOMAIN_SSL_DIR}/${DOMAIN}.key"
        log_message "拷贝 ${DOMAIN}.key 文件成功."

        # fullchain.crt（服务器 + 中级 CA）
        cp -f "${DOMAIN_DIR}/fullchain.pem" "${DOMAIN_SSL_DIR}/fullchain.crt"
        chmod 0755 "${DOMAIN_SSL_DIR}/fullchain.crt"
        log_message "拷贝 fullchain.crt（服务器 + 中级CA）成功."

        # issuer_certificate.crt（单独的中级 CA）
        if [ -f "${DOMAIN_DIR}/ca.cer" ]; then
            cp -f "${DOMAIN_DIR}/ca.cer" "${DOMAIN_SSL_DIR}/issuer_certificate.crt"
            chmod 0755 "${DOMAIN_SSL_DIR}/issuer_certificate.crt"
            log_message "拷贝 issuer_certificate.crt（中级CA）成功."
        else
            log_message "未找到 ${DOMAIN_DIR}/ca.cer，跳过 issuer_certificate.crt 拷贝"
        fi
    fi

    # —— 获取新证书的到期日期、颁发机构，并更新数据库 ——  
	# 1) 过期时间（毫秒级）
	NEW_EXPIRY_DATE=$(openssl x509 -enddate -noout -in "${DOMAIN_DIR}/fullchain.pem" \
	  | sed "s/^.*=\(.*\)$/\1/")
	NEW_EXPIRY_TIMESTAMP=$(date -d "$NEW_EXPIRY_DATE" +%s%3N)

	# 2) 颁发机构：从证书里读取颁发机构
    ISSUER=$(openssl x509 -in "${ACME_DIR}${DOMAIN}_ecc/fullchain.pem" -noout -issuer | sed -n 's/^.*CN *= *\([^,]*\).*$/\1/p')

	# 3) 当前时间（毫秒）
	NOW_MS=$(date +%s%3N)

	# 4) 把单引号转义成两个单引号，防止 SQL 报错
	ISSUER_SQL=${ISSUER//\'/\'\'}

	log_message "${DOMAIN} 新证书到期：$NEW_EXPIRY_DATE，颁发机构：$ISSUER"

	# 5) 更新所有字段
	psql -U postgres -d trim_connect -c "UPDATE cert SET valid_to = $NEW_EXPIRY_TIMESTAMP, issued_by = '$ISSUER_SQL', updated_time = $NOW_MS WHERE domain = '$DOMAIN';"

    # 重启相关服务
    log_message "重启相关服务..."
    sudo systemctl restart webdav.service
    sudo systemctl restart smbftpd.service
    sudo systemctl restart trim_nginx.service
    log_message "服务重启完成！"
done

# 处理 DOMAINS2 列表
for DOMAIN in "${DOMAINS2[@]}"; do
    DOMAIN_DIR="${ACME_DIR}${DOMAIN}_ecc"               # 域名证书存放目录

    # 证书有效期检查
    if [ "$TEST_MODE" -eq 0 ]; then
      CERT_FILE="${DOMAIN_DIR}/fullchain.pem"
      check_cert_expiry "$CERT_FILE" || continue
    else
      log_message "测试模式：跳过 ${DOMAIN} 的证书有效期检查，强制更新"
    fi

    # 删除指定域名的旧证书文件夹
    log_message "删除 ${DOMAIN} 的旧证书文件夹路径：${DOMAIN_DIR}..."
    rm -rf "${DOMAIN_DIR}"/*

    # 运行 acme.sh 申请新证书
    log_message "通过 acme.sh 申请新的证书 ${DOMAIN}..."
          
    # 构造所有 API 环境变量
	env_args=()
	for name in "${PARAM_NAMES[@]}"; do
	  env_args+=( "-e" "$name=${!name}" )
	done

	# 申请证书
	docker exec "${env_args[@]}" acme.sh /root/.acme.sh/acme.sh \
      --issue --dns "$DNS_PROVIDER" -d "$DOMAIN" --force

	# 安装证书（含 ca.cer）
	docker exec "${env_args[@]}" acme.sh /root/.acme.sh/acme.sh \
      --install-cert -d "$DOMAIN" \
	  --key-file      "/acme.sh/${DOMAIN}_ecc/privkey.pem" \
	  --fullchain-file "/acme.sh/${DOMAIN}_ecc/fullchain.pem" \
	  --ca-file       "/acme.sh/${DOMAIN}_ecc/ca.cer"

    # 生成 .pfx 文件
    log_message "生成 ${DOMAIN}.pfx 文件..."
    openssl pkcs12 -export -in "${DOMAIN_DIR}/fullchain.pem" -inkey "${DOMAIN_DIR}/privkey.pem" -out "${DOMAIN_DIR}/${DOMAIN}.pfx" -password pass:$PASSWORD

    # 拷贝 .pfx 文件到指定目录
    log_message "拷贝 ${DOMAIN}.pfx 到指定目录 ${PFX_DIR}..."
    mkdir -p "${PFX_DIR}"
    cp -f "${DOMAIN_DIR}/${DOMAIN}.pfx" "${PFX_DIR}/"
    chmod 0755 "${PFX_DIR}/${DOMAIN}.pfx"
    log_message "${DOMAIN}.pfx 生成并拷贝到 ${PFX_DIR} 成功！"
done

# 停止 Docker 容器
echo "=== 停止 acme.sh 容器中 ==="
docker stop acme.sh
echo "acme.sh 容器已停止。"

# 完成日志
log_message "所有证书替换完成"
echo '所有证书替换完成'
