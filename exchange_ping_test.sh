#!/bin/bash

# 加密货币交易所延迟测试脚本
# 测试服务器到各大交易所的API响应延迟

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 交易所配置 (使用索引数组以兼容 bash 3.2)
EXCHANGE_NAMES=(
    "币安(Binance)"
    "Gate.io"
    "Bitget"
    "Bybit"
    "OKX"
)

EXCHANGE_URLS=(
    "https://api.binance.com/api/v3/ping"
    "https://api.gateio.ws/api/v4/spot/time"
    "https://api.bitget.com/api/spot/v1/public/time"
    "https://api.bybit.com/v5/market/time"
    "https://www.okx.com/api/v5/public/time"
)

# 测试轮数
TEST_ROUNDS=10
TIMEOUT=5

# 运行时可选开关（通过环境变量覆盖）
# 例：NO_KEEPALIVE=1 FORCE_IPV4=1 TEST_ROUNDS=20 bash exchange_ping_test.sh
NO_KEEPALIVE=${NO_KEEPALIVE:-0}   # 1=每次请求关闭连接，避免连接复用带来的偏差
FORCE_IPV4=${FORCE_IPV4:-0}       # 1=仅用 IPv4
FORCE_IPV6=${FORCE_IPV6:-0}       # 1=仅用 IPv6

# 数学实现后端：优先使用 bc；若无 bc 则在 main 中切换为 awk
MATH_IMPL="bc"

# 浮点数比较函数
float_gt() {
    local result
    if [ "$MATH_IMPL" = "awk" ]; then
        result=$(awk -v a="$1" -v b="$2" 'BEGIN{print (a>b)?1:0}')
    else
        result=$(echo "$1 > $2" | bc 2>/dev/null)
    fi
    [ "$result" = "1" ]
}

float_lt() {
    local result
    if [ "$MATH_IMPL" = "awk" ]; then
        result=$(awk -v a="$1" -v b="$2" 'BEGIN{print (a<b)?1:0}')
    else
        result=$(echo "$1 < $2" | bc 2>/dev/null)
    fi
    [ "$result" = "1" ]
}

# 测试单次延迟
test_latency() {
    local url=$1
    # 根据环境变量拼装 curl 额外参数
    local -a extra_opts=()
    if [ "$NO_KEEPALIVE" = "1" ]; then
        extra_opts+=(--http1.1 -H 'Connection: close')
    fi
    if [ "$FORCE_IPV4" = "1" ]; then
        extra_opts+=(-4)
    fi
    if [ "$FORCE_IPV6" = "1" ]; then
        extra_opts+=(-6)
    fi

    local result=$(curl -o /dev/null -s -w '%{time_total}\n' \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        "${extra_opts[@]}" "$url" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$result" ]; then
        # 转换为毫秒
        if [ "$MATH_IMPL" = "awk" ]; then
            awk -v t="$result" 'BEGIN{printf "%.6f\n", t*1000}'
        else
            echo "scale=6; $result * 1000" | bc 2>/dev/null
        fi
    else
        echo "-1"
    fi
}

# 计算平均值
calculate_average() {
    local sum=0
    local count=0

    if [ "$MATH_IMPL" = "awk" ]; then
        # 使用 awk 计算平均值，避免依赖 bc
        printf '%s\n' "$@" | awk '{v=$1+0; if(v>0){sum+=v; c++}} END{ if(c>0){printf "%.2f\n", sum/c} else {print -1} }'
    else
        for val in "$@"; do
            if float_gt "$val" 0; then
                sum=$(echo "$sum + $val" | bc 2>/dev/null)
                count=$((count + 1))
            fi
        done

        if [ $count -gt 0 ]; then
            echo "scale=2; $sum / $count" | bc 2>/dev/null
        else
            echo "-1"
        fi
    fi
}

# 获取最小值
get_min() {
    local min=-1
    for val in "$@"; do
        if float_gt "$val" 0; then
            if [ "$min" == "-1" ] || float_lt "$val" "$min"; then
                min=$val
            fi
        fi
    done
    echo "$min"
}

# 获取最大值
get_max() {
    local max=-1
    for val in "$@"; do
        if float_gt "$val" 0; then
            if [ "$max" == "-1" ] || float_gt "$val" "$max"; then
                max=$val
            fi
        fi
    done
    echo "$max"
}

# 测试单个交易所
test_exchange() {
    local name=$1
    local url=$2

    echo -e "\n${BLUE}正在测试 ${name}...${NC}" >&2

    local -a latencies=()
    local success_count=0

    # 使用 C 风格循环以避免对 seq 的依赖（macOS/最小系统兼容）
    local i
    for ((i = 1; i <= TEST_ROUNDS; i++)); do
        local latency
        latency=$(test_latency "$url")

        if float_gt "$latency" 0; then
            latencies+=("$latency")
            printf "  第 %2d 次: ${GREEN}%.2f ms${NC}\n" $i $latency >&2
            success_count=$((success_count + 1))
        else
            printf "  第 %2d 次: ${RED}失败${NC}\n" $i >&2
        fi

        sleep 0.1
    done

    if [ $success_count -eq 0 ]; then
        echo "$name|-1|-1|-1|0"
        return
    fi

    local avg=$(calculate_average "${latencies[@]}")
    local min=$(get_min "${latencies[@]}")
    local max=$(get_max "${latencies[@]}")
    local success_rate
    if [ "$MATH_IMPL" = "awk" ]; then
        success_rate=$(awk -v s="$success_count" -v t="$TEST_ROUNDS" 'BEGIN{printf "%.1f", (s*100.0)/t}')
    else
        success_rate=$(echo "scale=1; $success_count * 100 / $TEST_ROUNDS" | bc 2>/dev/null)
    fi

    echo "$name|$min|$avg|$max|$success_rate"
}

# 打印结果
print_results() {
    echo ""
    echo "======================================================================"
    echo "测试时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================================"
    printf "%-20s %-12s %-12s %-12s %-10s\n" "交易所" "最小延迟" "平均延迟" "最大延迟" "成功率"
    echo "----------------------------------------------------------------------"

    local fastest_name=""
    local fastest_avg=-1

    while IFS='|' read -r name min avg max success_rate; do
        if float_gt "$avg" 0; then
            printf "%-20s %8.2f ms  %8.2f ms  %8.2f ms  %6.1f%%\n" \
                "$name" "$min" "$avg" "$max" "$success_rate"

            if [ "$fastest_avg" == "-1" ] || float_lt "$avg" "$fastest_avg"; then
                fastest_avg=$avg
                fastest_name=$name
            fi
        else
            printf "%-20s ${RED}测试失败${NC}\n" "$name"
        fi
    done < "$1"

    echo "======================================================================"

    if [ -n "$fastest_name" ]; then
        # 使用 printf 确保数值格式，如 0.04 而不是 .04
        printf "\n${GREEN}🚀 最快交易所: %s (平均延迟: %.2f ms)${NC}\n" \
            "$fastest_name" "$fastest_avg"
    fi
}

# 主函数
main() {
    echo "======================================================================"
    echo "加密货币交易所延迟测试"
    echo "======================================================================"
    echo "测试交易所数量: ${#EXCHANGE_NAMES[@]}"
    echo "每个交易所测试 $TEST_ROUNDS 次"

    # 检查依赖
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}错误: 未找到 curl 命令，请先安装 curl${NC}"
        exit 1
    fi

    # 选择数学后端：优先 bc；若无 bc 则回退 awk
    if ! command -v bc &> /dev/null; then
        if command -v awk &> /dev/null; then
            MATH_IMPL="awk"
            echo -e "${YELLOW}提示: 未找到 bc，已自动使用 awk 进行浮点计算${NC}"
        else
            echo -e "${RED}错误: 未找到 bc 或 awk，请先安装其中之一${NC}"
            exit 1
        fi
    fi

    # 创建临时文件存储结果
    local temp_file=$(mktemp)

    # 测试每个交易所
    for i in "${!EXCHANGE_NAMES[@]}"; do
        test_exchange "${EXCHANGE_NAMES[$i]}" "${EXCHANGE_URLS[$i]}" >> "$temp_file"
    done

    # 打印结果
    print_results "$temp_file"

    # 清理临时文件
    rm -f "$temp_file"
}

# 捕获 Ctrl+C
trap 'echo -e "\n\n${YELLOW}测试已取消${NC}"; exit 130' INT

# 运行主函数
main
