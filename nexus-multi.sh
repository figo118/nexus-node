#!/bin/bash
set -e

# ✅ 全局配置变量
DEFAULT_THREADS=8
NEXUS_START_FLAGS="--headless --max-threads $DEFAULT_THREADS"
BASE_DIR="/root/nexus-node"
IMAGE_NAME="nexus-node:latest"
BUILD_DIR="$BASE_DIR/build"
LOG_DIR="$BASE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"

# ✅ 检查是否安装 jq
command -v jq >/dev/null 2>&1 || {
    echo "❌ 缺少 jq 命令，请先安装：sudo apt install -y jq" >&2
    exit 1
}

# ✅ 优化目录权限
function init_dirs() {
    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$CONFIG_DIR"
    chmod 755 "$LOG_DIR"
    sudo chown -R $USER:$USER "$BASE_DIR" 2>/dev/null || true
}

function check_docker() {
    if ! [ -x "$(command -v docker)" ]; then
        echo "Docker 未安装，正在安装..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update && apt install -y docker-ce
        systemctl enable docker && systemctl start docker
    fi
}

function prepare_build_files() {
  mkdir -p "$BUILD_DIR"

  cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# 基础依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl git build-essential pkg-config libssl-dev \
    clang libclang-dev cmake jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 安装 rustup + 最新 nightly
RUN curl --retry 3 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# 拉取 nexus-cli 源码
WORKDIR /app
RUN git clone --depth=1 https://github.com/nexus-xyz/nexus-cli.git

# 构建
WORKDIR /app/nexus-cli/clients/cli
RUN cargo build --release && \
    strip target/release/nexus-network && \
    cp target/release/nexus-network /usr/local/bin/ && \
    chmod +x /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

  cat > "$BUILD_DIR/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e

case "$1" in
    --version|--help|version|help)
        exec nexus-network "$@"
        ;;
esac

: "${NODE_ID:?❌ 必须设置 NODE_ID 环境变量}"
: "${MAX_THREADS:=8}"

LOG_DIR="/nexus-data"
LOG_FILE="${LOG_DIR}/nexus-${NODE_ID}.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

echo "▶️ 启动节点: $NODE_ID | 线程数: $MAX_THREADS | 日志文件: $LOG_FILE"

exec nexus-network start \
    --node-id "$NODE_ID" \
    --max-threads "$MAX_THREADS" \
    --headless \
    2>&1 | tee -a "$LOG_FILE"
EOF

  chmod +x "$BUILD_DIR/entrypoint.sh"
}

# ✅ 增加镜像存在检查
function build_image() {
    cd "$BUILD_DIR"
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        read -rp "镜像已存在，是否重新构建？[y/N] " choice
        [[ "$choice" != [yY] ]] && return
    fi

    echo "🔧 开始构建 Docker 镜像..."
    docker build --no-cache -t "$IMAGE_NAME" . || {
        echo "❌ 镜像构建失败" >&2
        exit 1
    }

    echo "✅ 镜像构建完成，版本信息："
    docker run --rm --entrypoint nexus-network "$IMAGE_NAME" --version || {
        echo "⚠️ 版本检查失败" >&2
    }
}

function build_image_latest() {
    cd "$BUILD_DIR"
    echo "🔧 正在更新到官方最新版..."
    docker build -t "$IMAGE_NAME" . || {
        echo "❌ 镜像构建失败" >&2
        exit 1
    }
    echo "✅ 镜像更新完成，当前版本："
    docker run --rm --entrypoint nexus-network "$IMAGE_NAME" --version
}

function validate_node_id() {
    [[ "$1" =~ ^[0-9]+$ ]] || {
        echo "❌ node-id 必须是数字" >&2
        return 1
    }
    return 0
}

# ✅ 使用全局启动参数
function start_instances() {
    read -rp "请输入要创建的实例数量: " INSTANCE_COUNT
    [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "❌ 请输入有效数字"; exit 1; }

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        while true; do
            read -rp "请输入第 $i 个实例的 node-id: " NODE_ID
            validate_node_id "$NODE_ID" && break
        done

        # ✅ 增强版冲突检查
        if docker inspect "nexus-node-$i" &>/dev/null; then
            read -rp "容器 nexus-node-$i 已存在，是否替换？[y/N] " choice
            if [[ "$choice" =~ ^[yY] ]]; then
                echo "🔄 正在移除旧容器..."
                docker rm -f "nexus-node-$i" || {
                    echo "❌ 容器删除失败，跳过此实例"
                    continue
                }
            else
                echo "⏩ 跳过实例 nexus-node-$i"
                continue
            fi
        fi

        # 启动新实例
        if ! docker run -dit \
            --name "nexus-node-$i" \
            -e NODE_ID="$NODE_ID" \
            -v "$LOG_DIR":/nexus-data \
            "$IMAGE_NAME" \
            start --node-id "$NODE_ID" --max-threads 8 --headless; then
            echo "❌ 实例 nexus-node-$i 启动失败"
            continue
        fi
        
        echo "✅ 实例 nexus-node-$i 启动成功 (node-id: $NODE_ID)"
    done
}

function add_one_instance() {
    # 获取最大编号（兼容非数字容器名）
    MAX_ID=$(docker ps --filter "name=nexus-node-" --format '{{.Names}}' | 
             awk -F'-' '{if($NF ~ /^[0-9]+$/) print $NF}' | 
             sort -n | 
             tail -n 1)

    # 计算下一个可用编号
    NEXT_IDX=$(( ${MAX_ID:-0} + 1 ))

    while true; do
        read -rp "请输入 node-id (必须为数字): " NODE_ID
        [[ "$NODE_ID" =~ ^[0-9]+$ ]] && break
        echo "❌ node-id 必须是数字！"
    done

    # 启动实例
    docker run -dit \
        --name "nexus-node-${NEXT_IDX}" \
        -e NODE_ID="$NODE_ID" \
        -v "$LOG_DIR":/nexus-data \
        "$IMAGE_NAME" \
        start --node-id "$NODE_ID" --max-threads 8 --headless

    echo "✅ 实例 nexus-node-${NEXT_IDX} 启动成功（线程数:8）"
}

function restart_node() {
    containers=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^nexus-node-[0-9]+$ ]]; then
            containers+=("$line")
        fi
    done < <(docker ps --filter "name=nexus-node-" --format "{{.Names}}")

    if [ ${#containers[@]} -eq 0 ]; then
        echo "⚠️ 没有运行中的实例"
        sleep 2
        return
    fi

    echo "请选择要重启的节点:"
    for i in "${!containers[@]}"; do
        echo "[$((i+1))] ${containers[i]}"
    done
    echo "[a] 重启所有节点"
    echo "[0] 返回"

    read -rp "请输入选择: " choice
    case "$choice" in
        [1-9])
            if [ "$choice" -le "${#containers[@]}" ]; then
                container="${containers[$((choice-1))]}"
                echo "🔄 正在重启 $container ..."
                if ! timeout 10s docker restart "$container"; then
                    echo "❌ 重启超时，尝试强制停止..."
                    docker stop -t 2 "$container" && docker start "$container"
                fi
            fi
            ;;
        a|A)
            for container in "${containers[@]}"; do
                echo "🔄 正在重启 $container ..."
                if ! timeout 10s docker restart "$container"; then
                    echo "❌ $container 重启超时，尝试强制停止..."
                    docker stop -t 2 "$container" && docker start "$container"
                fi
            done
            ;;
    esac
    read -rp "按 Enter 继续..."
}
function calculate_uptime() {
    local container=$1
    local created=$(docker inspect --format '{{.Created}}' "$container")
    local restarts=$(docker inspect --format '{{.RestartCount}}' "$container")
    local started=$(docker inspect --format '{{.State.StartedAt}}' "$container")
    
    local now=$(date +%s)
    local created_ts=$(date -d "$created" +%s)
    local started_ts=$(date -d "$started" +%s)
    
    if [ "$restarts" -gt 0 ]; then
        local prev_uptime=$((created_ts - started_ts))
        local curr_uptime=$((now - started_ts))
        local total_seconds=$((prev_uptime + curr_uptime))
    else
        local total_seconds=$((now - started_ts))
    fi
    
    local hours=$((total_seconds / 3600))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    printf "%02d时%02dm" "$hours" "$minutes"
}
function show_container_logs() {
    containers=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^nexus-node-[0-9]+$ ]]; then
            containers+=("$line")
        fi
    done < <(docker ps --filter "name=nexus-node-" --format "{{.Names}}")

    while true; do
        clear
        echo "Nexus 节点日志查看"
        echo "--------------------------------"

        if [ ${#containers[@]} -eq 0 ]; then
            echo "⚠️ 没有运行中的实例"
            sleep 2
            return
        fi

        for i in "${!containers[@]}"; do
            status=$(docker inspect -f '{{.State.Status}}' "${containers[i]}")
            node_id=$(docker inspect "${containers[i]}" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^NODE_ID=" | cut -d= -f2)
            echo "[$((i+1))] ${containers[i]} (状态: $status | 节点ID: ${node_id:-未设置})"
        done

        echo
        echo "[0] 返回主菜单"
        read -rp "请选择容器: " input

        [[ "$input" == "0" ]] && return
        [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -le "${#containers[@]}" ] && {
            container="${containers[$((input-1))]}"
            clear
            echo "🔍 实时日志: $container (Ctrl+C 退出)"
            echo "--------------------------------"
            trap "echo; return 0" SIGINT
            docker logs -f --tail=20 "$container"
            trap - SIGINT
            read -rp "按 Enter 继续..."
        }
    done
}

function show_menu() {
    clear
    # 绿色NEXUS标题（清晰版）
    echo -e "${GREEN}"
    echo "  N   N  EEEEE  X   X  U   U  SSSSS"
    echo "  NN  N  E       X X   U   U  S    "
    echo "  N N N  EEE      X    U   U  SSSSS"
    echo "  N  NN  E       X X   U   U      S"
    echo "  N   N  EEEEE  X   X   UUU   SSSSS"
    echo -e "${NC}"
    
    # 副标题（带行距）
    echo -e "\n${CYAN}      ░N░E░X░U░S░ 节点管理控制台 v2.0${NC}"
   echo -e "${BLUE}==============================================${NC}"
    
    # 系统资源（严格对齐）
    printf "${YELLOW}🖥️ 系统资源 ${BLUE}CPU:${GREEN}%-2d核 ${BLUE}内存:${GREEN}%-5s${NC}\n" \
           $(nproc) $(free -h | awk '/Mem:/{print $4}')
    echo -e "${BLUE}---------------------------------------${NC}"
    
    # 节点表格（精确对齐）
    printf "${CYAN}%-14s %-15s %-12s %-12s\n${NC}" "容器名称" "节点ID" "运行时间" "完成任务数"
    echo -e "${BLUE}---------------------------------------${NC}"
    
    while read -r name; do
        node_id=$(docker inspect $name --format '{{.Config.Env}}' | grep -o 'NODE_ID=[0-9]*' | cut -d= -f2)
        uptime=$(calculate_uptime "$name")
        tasks=$(grep -c "Proof submitted" "/root/nexus-node/logs/nexus-${node_id}.log" 2>/dev/null || echo 0)
        
        printf "${PURPLE}%-14s${NC} ${GREEN}%-11s${NC} ${YELLOW}%-9s${NC} ${RED}%-12s${NC}\n" \
               "$name" "$node_id" "$uptime" "$tasks tasks"
    done < <(docker ps --filter "name=nexus-node-" --format "{{.Names}}")
    
    # 功能菜单（7个选项）
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${CYAN}1. 构建镜像   2. 启动实例   3. 停止所有${NC}"
    echo -e "${CYAN}4. 实时日志   5. 重启节点   6. 添加实例${NC}"
    echo -e "${CYAN}7. 更新版本   0. 退出${NC}"
    echo -e "${BLUE}==============================================${NC}"
}

# ========== 主程序 ==========
check_docker
init_dirs

while true; do
    show_menu
    read -rp "请选择操作: " choice
    case "$choice" in
        1) prepare_build_files; build_image;;
        2) start_instances;;
        3) docker rm -f $(docker ps -aq --filter "name=nexus-node-") 2>/dev/null || true;;
        4) show_container_logs;;
        5) restart_node;;
        6) add_one_instance ;;
        7) prepare_build_files; build_image_latest ;;
        0) echo "退出"; exit 0;;
        *) echo "无效选项";;
    esac
    read -rp "按 Enter 继续..."
done
