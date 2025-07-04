#!/bin/bash
set -e

# ✅ 检查是否安装 jq
command -v jq >/dev/null 2>&1 || {
    echo "❌ 缺少 jq 命令，请先安装：sudo apt install -y jq" >&2
    exit 1
}

BASE_DIR="/root/nexus-node"
IMAGE_NAME="nexus-node:latest"
BUILD_DIR="$BASE_DIR/build"
LOG_DIR="$BASE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"

function init_dirs() {
    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$CONFIG_DIR"
    chmod 777 "$LOG_DIR"
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

ARG http_proxy
ARG https_proxy

RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    curl git build-essential pkg-config libssl-dev \
    clang libclang-dev cmake jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /root/.cargo && \
    echo '[source.crates-io]' > /root/.cargo/config.toml && \
    echo 'replace-with = "ustc"' >> /root/.cargo/config.toml && \
    echo '[source.ustc]' >> /root/.cargo/config.toml && \
    echo 'registry = "https://mirrors.ustc.edu.cn/crates.io-index"' >> /root/.cargo/config.toml && \
    echo '[net]' >> /root/.cargo/config.toml && \
    echo 'git-fetch-with-cli = true' >> /root/.cargo/config.toml && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y

ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /tmp
RUN git clone https://github.com/nexus-xyz/nexus-cli.git
WORKDIR /tmp/nexus-cli

WORKDIR /tmp/nexus-cli/clients/cli
RUN RUST_BACKTRACE=full cargo build --release

RUN cp target/release/nexus-network /usr/local/bin/ && chmod +x /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > "$BUILD_DIR/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e

[ -z "$NODE_ID" ] && {
    echo "❌ 必须设置 NODE_ID 环境变量" >&2
    exit 1
}

LOG_FILE="/nexus-data/nexus-${NODE_ID}.log"
mkdir -p /nexus-data
touch "$LOG_FILE"
echo "▶️ 正在启动节点：$NODE_ID，日志写入 $LOG_FILE"
MAX_THREADS=${MAX_THREADS:-4}
exec nexus-network start --node-id "$NODE_ID" --max-threads "$MAX_THREADS" 2>&1 | tee -a "$LOG_FILE"
EOF

    chmod +x "$BUILD_DIR/entrypoint.sh"
}

function build_image() {
    cd "$BUILD_DIR"
    echo "🔧 开始构建 Docker 镜像..."
    docker build --no-cache -t "$IMAGE_NAME" . || {
        echo "❌ 镜像构建失败" >&2
        exit 1
    }
    echo "✅ 镜像构建完成"
}

function validate_node_id() {
    [[ "$1" =~ ^[0-9]+$ ]] || {
        echo "❌ node-id 必须是数字" >&2
        return 1
    }
    return 0
}
function start_instances() {
    read -rp "请输入要创建的实例数量: " INSTANCE_COUNT
    [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "❌ 请输入有效数字" >&2; exit 1; }

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        while true; do
            read -rp "请输入第 $i 个实例的 node-id: " NODE_ID
            validate_node_id "$NODE_ID" && break
        done

        CONTAINER_NAME="nexus-node-$i"
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

        docker run -dit \
            --name "$CONTAINER_NAME" \
            --memory=2g \
            --cpus=1 \
            -e NODE_ID="$NODE_ID" \
            -e MAX_THREADS=1 \
            -v "$LOG_DIR":/nexus-data \
            "$IMAGE_NAME"

        echo "✅ 实例 $CONTAINER_NAME 启动成功（线程数: 1，内存限制: 2GB）"
    done
}

function add_one_instance() {
    NEXT_IDX=$(docker ps -a --filter "name=nexus-node-" --format '{{.Names}}' | sed 's/nexus-node-//' | sort -n | tail -1 | awk '{print $1+1}')
    [ -z "$NEXT_IDX" ] && NEXT_IDX=1

    while true; do
        read -rp "请输入新的实例的 node-id: " NODE_ID
        validate_node_id "$NODE_ID" && break
    done

    CONTAINER_NAME="nexus-node-$NEXT_IDX"
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    docker run -dit \
        --name "$CONTAINER_NAME" \
        --memory=2g \
        --cpus=1 \
        -e NODE_ID="$NODE_ID" \
        -e MAX_THREADS=1 \
        -v "$LOG_DIR":/nexus-data \
        "$IMAGE_NAME"

    echo "✅ 新实例 $CONTAINER_NAME 启动成功（线程数: 1，内存限制: 1GB）"
}

function restart_node() {
    containers=($(docker ps --filter "name=nexus-node-" --format "{{.Names}}"))
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
                docker restart "$container"
                echo "✅ $container 已重启"
            else
                echo "❌ 无效的选择"
            fi
            ;;
        a|A)
            echo "🔄 正在重启所有节点..."
            for container in "${containers[@]}"; do
                docker restart "$container"
                echo "✅ $container 已重启"
            done
            ;;
        0)
            return
            ;;
        *)
            echo "❌ 无效的选择"
            ;;
    esac
    read -rp "按 Enter 继续..."
}

function show_container_logs() {
    while true; do
        clear
        echo "Nexus 节点日志查看"
        echo "--------------------------------"

        containers=($(docker ps --filter "name=nexus-node-" --format "{{.Names}}"))
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
        echo "--------------------------------"
        read -rp "请选择要查看的容器: " input

        if [[ "$input" == "0" ]]; then
            return
        fi

        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#containers[@]}" ]; then
            container_name="${containers[$((input-1))]}"
            
            clear
            echo -e "\n🔍 实时监控: $container_name (Ctrl+C 停止)"
            echo "--------------------------------"
            
            trap "echo -e '\n🛑 已停止监控'; return 0" SIGINT
            docker logs -f --tail=20 "$container_name" 2>&1
            
            trap - SIGINT
            read -rp "按 Enter 继续..."
        else
            echo "❌ 无效的容器编号"
            sleep 1
        fi
    done
}

function show_menu() {
    clear
    echo "========== Nexus 节点管理 ==========="
    echo "📂 日志目录: $LOG_DIR"
    echo
    echo "📊 当前资源使用情况："
    echo -e "容器\t\t节点ID\t\tCPU\t内存\t\t占用率"

    containers=$(docker ps --filter "name=nexus-node-" --format "{{.Names}}")
    if [ -z "$containers" ]; then
        echo "暂无实例运行"
    else
        for name in $containers; do
            NODE_ID=$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep NODE_ID= | cut -d= -f2)
            stats=$(docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}" "$name")
            CPU=$(echo "$stats" | cut -d'|' -f1)
            MEM=$(echo "$stats" | cut -d'|' -f2)
            PCT=$(echo "$stats" | cut -d'|' -f3)
            printf "%-15s %-10s %-6s %-16s %s\n" "$name" "$NODE_ID" "$CPU" "$MEM" "$PCT"
        done
    fi
    echo
    echo "1. 构建镜像"
    echo "2. 启动多个实例"
    echo "3. 停止所有实例"
    echo "4. 查看实时日志"
    echo "5. 重启节点"
    echo "6. 添加单个实例"
    echo "0. 退出"
    echo "======================================"
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
        3) docker rm -f $(docker ps -aq --filter "name=nexus-node-") || true;;
        4) show_container_logs;;
        5) restart_node;;
        6) add_one_instance ;;
        0) echo "退出"; exit 0;;
        *) echo "无效选项";;
    esac
    read -rp "按 Enter 继续..."
done
