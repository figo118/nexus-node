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

    cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl git build-essential pkg-config libssl-dev \
    clang libclang-dev cmake jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

RUN git clone https://github.com/nexus-xyz/nexus-cli.git /tmp/nexus-cli && \
    cd /tmp/nexus-cli/clients/cli && \
    RUST_BACKTRACE=full cargo build --release && \
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
: "${MAX_THREADS:?❌ 必须设置 MAX_THREADS 环境变量}"

LOG_DIR="/nexus-data"
LOG_FILE="${LOG_DIR}/nexus-${NODE_ID}.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

echo "▶️ 启动节点: $NODE_ID | 线程数: $MAX_THREADS | 日志文件: $LOG_FILE"
exec nexus-network start \
    --node-id "$NODE_ID" \
    --max-threads "$MAX_THREADS" \
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

        # ✅ 新增冲突检查
        if docker inspect "nexus-node-$i" &>/dev/null; then
            echo "⚠️ 容器 nexus-node-$i 已存在，正在删除..."
            docker rm -f "nexus-node-$i"
        fi

        docker run -dit \
            --name "nexus-node-$i" \
            -e NODE_ID="$NODE_ID" \
            -v "$LOG_DIR":/nexus-data \
            "$IMAGE_NAME" \
            start --node-id "$NODE_ID" --max-threads 8 --headless
        echo "✅ 实例 nexus-node-$i 启动成功"
    done
}

function add_one_instance() {
    # 自动计算下一个可用编号（避免冲突）
    NEXT_IDX=$(($(docker ps -aq --filter "name=nexus-node-" --format "{{.Names}}" | sed 's/nexus-node-//' | sort -n | tail -1) + 1))
    [ -z "$NEXT_IDX" ] && NEXT_IDX=1  # 若没有现存实例，从1开始

    while true; do
        read -rp "请输入 node-id (必须为数字): " NODE_ID
        [[ "$NODE_ID" =~ ^[0-9]+$ ]] && break
        echo "❌ node-id 必须是数字！"
    done

    # 强制清理可能存在的同名容器
    docker rm -f "nexus-node-$NEXT_IDX" 2>/dev/null || true

    # 启动实例（固定线程数8和无头模式）
    docker run -dit \
        --name "nexus-node-$NEXT_IDX" \
        -e NODE_ID="$NODE_ID" \
        -v "$LOG_DIR":/nexus-data \
        "$IMAGE_NAME" \
        start --node-id "$NODE_ID" --max-threads 8 --headless

    echo "✅ 实例 nexus-node-$NEXT_IDX 启动成功（线程数:8）"
}
function restart_node() {
    containers=()
    while IFS= read -r line; do
        containers+=("$line")
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

# ✅ 使用数组处理容器名
function show_container_logs() {
    containers=()
    while IFS= read -r line; do
        containers+=("$line")
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

# ✅ 资源统计
function show_menu() {
    clear
    echo "========== Nexus 节点管理 ==========="
    echo "🖥️  系统资源：CPU $(nproc)核 | 内存: $(free -h | awk '/Mem:/{print $4}')可用"
    echo "📦 运行实例: $(docker ps -q --filter "name=nexus-node-" | wc -l)"
    echo "📂 日志目录: $LOG_DIR"
    echo "--------------------------------"

    containers=($(docker ps --filter "name=nexus-node-" --format "{{.Names}}"))
    if [ ${#containers[@]} -eq 0 ]; then
        echo "暂无运行中的实例"
    else
        echo -e "容器名称\t节点ID"
        for name in "${containers[@]}"; do
            node_id=$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep NODE_ID= | cut -d= -f2)
            echo -e "$name\t${node_id:-未设置}"
        done
    fi

    echo "--------------------------------"
    echo "1. 构建镜像"
    echo "2. 启动多个实例"
    echo "3. 停止所有实例"
    echo "4. 查看实时日志"
    echo "5. 重启节点"
    echo "6. 添加单个实例"
    echo "7. 更新到官方最新版"
    echo "0. 退出"
    echo "===================================="
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
