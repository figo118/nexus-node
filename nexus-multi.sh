#!/bin/bash
set -e

# ✅ 基础配置
BASE_DIR="/root/nexus-node"
IMAGE_NAME="nexus-node:latest"
BUILD_DIR="$BASE_DIR/build"
LOG_DIR="$BASE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"

# ✅ 初始化目录
function init_dirs() {
    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$CONFIG_DIR"
    chmod 777 "$LOG_DIR"
}

# ✅ 检查Docker环境
function check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "❌ Docker未安装，正在自动安装..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
}

# ✅ 构建镜像（优化版）
function build_image() {
    clear
    echo -e "\033[1;36m🛠️ 镜像构建工具\033[0m"
    echo -e "\033[1;34m===============================================\033[0m"
    
    # 检查是否已存在镜像
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo -e "\033[1;33m⚠️ 已存在同名镜像 [$IMAGE_NAME]\033[0m"
        read -rp "是否删除旧镜像？(y/n) [n]: " remove_old
        if [[ "$remove_old" =~ ^[Yy]$ ]]; then
            docker rmi "$IMAGE_NAME" || {
                echo -e "\033[1;31m❌ 旧镜像删除失败\033[0m"
                return 1
            }
            echo -e "\033[1;32m✓ 旧镜像已删除\033[0m"
        fi
    fi

    echo -e "\033[1;33m🔧 正在准备构建文件...\033[0m"
    
    # 创建Dockerfile（带注释说明）
    cat > "$BUILD_DIR/Dockerfile" <<'EOF'
# Nexus 节点基础镜像
FROM ubuntu:24.04

# 避免安装过程中的交互提示
ENV DEBIAN_FRONTEND=noninteractive

# 安装基础依赖
RUN apt-get update && \
    apt-get install -y \
    curl \
    git \
    build-essential \
    ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /app

# 复制启动脚本
COPY entrypoint.sh /entrypoint.sh

# 设置入口点
ENTRYPOINT ["/entrypoint.sh"]
EOF

    # 创建更完善的entrypoint脚本
    cat > "$BUILD_DIR/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e

# 日志目录
LOG_DIR="/logs"
mkdir -p "$LOG_DIR"

# 启动日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/node-$NODE_ID.log"
}

log "🟢 节点 [$NODE_ID] 启动中..."

# 检查必要环境变量
if [ -z "$NODE_ID" ]; then
    log "❌ 错误: 未设置NODE_ID环境变量"
    exit 1
fi

# 主程序执行
log "🚀 启动应用程序..."
exec your-app --node-id="$NODE_ID" 2>&1 | tee -a "$LOG_DIR/node-$NODE_ID.log"
EOF

    chmod +x "$BUILD_DIR/entrypoint.sh"

    echo -e "\033[1;34m===============================================\033[0m"
    echo -e "\033[1;33m🚀 开始构建镜像 [$IMAGE_NAME]...\033[0m"
    
    # 显示构建进度
    docker build --no-cache \
        --progress plain \
        -t "$IMAGE_NAME" \
        "$BUILD_DIR" 2>&1 | while read -r line; do
        if [[ "$line" == *"ERROR"* ]]; then
            echo -e "\033[1;31m$line\033[0m"
        elif [[ "$line" == *"Step"* ]]; then
            echo -e "\033[1;36m$line\033[0m"
        else
            echo "$line"
        fi
    done

    # 检查构建结果
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo -e "\033[1;34m===============================================\033[0m"
        echo -e "\033[1;32m✅ 镜像构建成功 [$IMAGE_NAME]\033[0m"
        echo -e "\033[1;33m镜像信息:\033[0m"
        docker image inspect "$IMAGE_NAME" --format '{{.Id}}' | cut -d':' -f2 | head -c 12
        echo
        return 0
    else
        echo -e "\033[1;31m❌ 镜像构建失败\033[0m"
        return 1
    fi
}

# ✅ 启动多个实例（带日志轮动配置）
function start_instances() {
    # 检查镜像是否存在
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo -e "\033[1;31m❌ 错误: 镜像 [$IMAGE_NAME] 不存在，请先构建镜像\033[0m"
        return 1
    fi

    read -rp "请输入要启动的实例数量: " count
    [[ "$count" =~ ^[0-9]+$ ]] || { echo -e "\033[1;31m❌ 必须输入数字\033[0m"; return 1; }
    [[ "$count" -gt 20 ]] && { echo -e "\033[1;33m⚠️ 注意: 启动过多实例可能影响系统性能\033[0m"; }

    # 创建日志目录（如果不存在）
    mkdir -p "$LOG_DIR"

    for ((i=1; i<=count; i++)); do
        while true; do
            read -rp "实例 $i 的 node-id: " node_id
            [[ "$node_id" =~ ^[0-9]+$ ]] && break
            echo -e "\033[1;31m❌ node-id 必须是数字\033[0m"
        done

        # 为每个实例创建专属日志目录
        instance_log_dir="$LOG_DIR/node-$node_id"
        mkdir -p "$instance_log_dir"

        echo -e "\033[1;33m🚀 正在启动实例 $i (ID: $node_id)...\033[0m"

        # 启动容器并配置日志轮动
        docker run -d \
            --name "nexus-node-$i" \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --log-opt compress=true \
            -e NODE_ID="$node_id" \
            -v "$instance_log_dir:/logs" \
            -v /etc/localtime:/etc/localtime:ro \
            "$IMAGE_NAME" && \
        echo -e "\033[1;32m✅ 实例 $i 启动成功 (ID: $node_id)\n   日志目录: $instance_log_dir\033[0m" || \
        echo -e "\033[1;31m❌ 实例 $i 启动失败\033[0m"
    done

    echo -e "\n\033[1;34mℹ️ 日志轮动配置:\033[0m"
    echo -e "  - 单个日志文件最大: 10MB"
    echo -e "  - 保留最多: 3个备份文件"
    echo -e "  - 自动压缩旧日志"
}

# ✅ 停止所有实例
function stop_all_instances() {
    echo "🛑 正在停止所有实例..."
    docker rm -f $(docker ps -aq --filter "name=nexus-node-") 2>/dev/null || true
    echo "✅ 所有实例已停止"
}

function show_container_logs() {
    # 颜色定义
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    NC='\033[0m'
    
    while true; do
        clear
        echo -e "${GREEN}Nexus节点选择${NC}"
        echo "----------------"
        
        # 获取所有容器
        containers=($(docker ps --filter "name=nexus-node-" --format "{{.Names}}" | sort -V))
        total_nodes=${#containers[@]}
        
        # 显示简单菜单
        for i in "${!containers[@]}"; do
            printf "%2d) %s\n" $(($i+1)) "${containers[$i]}"
        done
        
        echo "----------------"
        echo -e "${RED}0) 退出${NC}"
        echo -ne "请选择节点编号 (1-${total_nodes}): "
        
        read choice
        # 退出判断
        [[ "$choice" == "0" ]] && break
        
        # 验证输入是否为数字且在有效范围内
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total_nodes" ]; then
            clear
            echo -e "${GREEN}=== ${containers[$((choice-1))]} 日志 ===${NC}"
            echo "（按CTRL+C返回菜单）"
            echo "----------------"
            docker logs --tail 20 "${containers[$((choice-1))]}"
            echo -e "\n${RED}按回车键继续...${NC}"
            read -n1
        else
            echo -e "${RED}无效输入！请输入1-${total_nodes}的数字${NC}"
            sleep 1
        fi
    done
}

# ✅ 重启节点
function restart_node() {
    while true; do
        clear
        echo -e "\033[1;36m🔄 节点重启管理\033[0m"
        echo -e "\033[1;34m===============================================\033[0m"
        
        # 获取运行中的容器
        containers=($(docker ps --filter "name=nexus-node-" --format "{{.Names}}"))
        
        if [[ ${#containers[@]} -eq 0 ]]; then
            echo -e "\033[1;33m⚠️ 没有运行中的实例\033[0m"
            read -rp "按Enter返回主菜单..."
            return
        fi

        # 显示容器列表
        for i in "${!containers[@]}"; do
            printf "%2d) %-20s\n" $((i+1)) "${containers[i]}"
        done
        
        echo -e "\033[1;34m===============================================\033[0m"
        echo -e " a) 重启所有节点"
        echo -e " 0) 返回主菜单"
        echo -e "\033[1;34m===============================================\033[0m"
        read -rp "请选择要重启的节点编号（或输入a/0）: " choice

        case "$choice" in
            0)
                return
                ;;
            a|A)
                echo -e "\033[1;33m🔄 正在重启所有节点...\033[0m"
                for container in "${containers[@]}"; do
                    docker restart "$container" && \
                    echo -e "\033[1;32m✓ ${container} 重启成功\033[0m" || \
                    echo -e "\033[1;31m✗ ${container} 重启失败\033[0m"
                done
                read -rp "操作完成，按Enter继续..."
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#containers[@]}" ]]; then
                    container="${containers[$((choice-1))]}"
                    echo -e "\033[1;33m🔄 正在重启 ${container}...\033[0m"
                    docker restart "$container" && \
                    echo -e "\033[1;32m✓ ${container} 重启成功\033[0m" || \
                    echo -e "\033[1;31m✗ ${container} 重启失败\033[0m"
                    read -rp "操作完成，按Enter继续..."
                else
                    echo -e "\033[1;31m❌ 无效输入，请重新选择\033[0m"
                    sleep 1
                fi
                ;;
        esac
    done
}

# ✅ 添加单个实例
function add_one_instance() {
    clear
    echo -e "\033[1;36m➕ 添加单个节点实例\033[0m"
    echo -e "\033[1;34m===============================================\033[0m"

    # 1. 检查镜像是否存在
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo -e "\033[1;31m❌ 错误: 镜像 [$IMAGE_NAME] 不存在，请先构建镜像\033[0m"
        read -rp "按Enter返回..."
        return 1
    fi

    # 2. 计算下一个可用序号（考虑已停止的容器）
    next_id=$(($(docker ps -aq --filter "name=nexus-node-" | wc -l)+1))
    used_ids=($(docker ps -aq --filter "name=nexus-node-" --format "{{.Names}}" | sed 's/nexus-node-//'))
    
    # 3. 获取有效的node-id
    while true; do
        read -rp "请输入节点ID (纯数字): " node_id
        if [[ ! "$node_id" =~ ^[0-9]+$ ]]; then
            echo -e "\033[1;31m❌ 必须输入纯数字ID\033[0m"
            continue
        fi
        
        # 检查ID是否已被使用
        if docker ps -aq --filter "env=NODE_ID=$node_id" | grep -q .; then
            echo -e "\033[1;33m⚠️ 该node-id已被使用\033[0m"
            continue
        fi
        break
    done

    # 4. 创建专属日志目录
    instance_log_dir="$LOG_DIR/node-$node_id"
    mkdir -p "$instance_log_dir"
    chmod 777 "$instance_log_dir"

    # 5. 启动容器（带完整参数）
    echo -e "\033[1;33m🚀 正在启动节点实例...\033[0m"
    docker run -d \
        --name "nexus-node-$next_id" \
        --restart unless-stopped \
        --log-driver json-file \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        -e NODE_ID="$node_id" \
        -v "$instance_log_dir:/logs" \
        -v /etc/localtime:/etc/localtime:ro \
        --network host \
        "$IMAGE_NAME" 2>&1 | tee -a "$LOG_DIR/deploy.log"

    # 6. 验证并显示结果
    if docker ps --filter "name=nexus-node-$next_id" | grep -q "nexus-node-$next_id"; then
        echo -e "\033[1;34m===============================================\033[0m"
        echo -e "\033[1;32m✅ 实例启动成功\033[0m"
        echo -e "容器名称: \033[1;36mnexus-node-$next_id\033[0m"
        echo -e "节点ID:   \033[1;33m$node_id\033[0m"
        echo -e "日志目录: \033[1;35m$instance_log_dir\033[0m"
        echo -e "\033[1;34m===============================================\033[0m"
    else
        echo -e "\033[1;31m❌ 实例启动失败，请检查日志: $LOG_DIR/deploy.log\033[0m"
    fi

    read -rp "按Enter返回主菜单..."
}
# ✅ 主菜单
function show_menu() {
    clear
    echo "🛠️ Nexus 节点管理 v2.2"
    echo "================================="
    echo "1. 构建镜像"
    echo "2. 启动多个实例"
    echo "3. 停止所有实例"
    echo "4. 查看实时日志"
    echo "5. 重启节点"
    echo "6. 添加单个实例"
    echo "0. 退出"
    echo "================================="
}

# ✅ 主程序
check_docker
init_dirs

while true; do
    show_menu
    read -rp "请选择操作: " choice
    
    case "$choice" in
        1) build_image ;;
        2) start_instances ;;
        3) stop_all_instances ;;
        4) show_container_logs ;;
        5) restart_node ;;
        6) add_one_instance ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
    read -rp "按Enter继续..."
done
