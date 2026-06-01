#!/usr/bin/env bash
# precommit-setup.sh — 安装 Android/Java Git pre-commit 钩子
#
# 检查项目：
# * Google Java Format - Java 代码格式化
# * Android Lint (仅 debug variant，按需启用)
# * Checkstyle - 代码风格检查（可选，有配置文件时启用）
# * 敏感信息检测（只扫描新增行）
#
# 使用方法：
#   chmod +x precommit-setup.sh
#   ./precommit-setup.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_FILE="$REPO_ROOT/.git/hooks/pre-commit"

echo "正在安装 pre-commit 钩子到: $HOOK_FILE"

cat > "$HOOK_FILE" << 'HOOK'
#!/usr/bin/env bash
# 自动生成的 pre-commit 钩子 — 请勿手动编辑
# 重新运行 precommit-setup.sh 来重新生成

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# 全局结果追踪
OVERALL_PASS=true

# 工具函数：打印带颜色的状态
pass()  { echo "  ✓ $*"; }
fail()  { echo "  ✗ $*"; OVERALL_PASS=false; }
warn()  { echo "  ⚠️  $*"; }
step()  { echo "> $*"; }

# ── 收集暂存文件列表（使用数组，避免路径含空格问题）─────────────────────

mapfile -t STAGED_JAVA < <(git diff --cached --name-only --diff-filter=ACM | grep '\.java$' || true)
mapfile -t STAGED_KT   < <(git diff --cached --name-only --diff-filter=ACM | grep '\.kt$'   || true)
mapfile -t STAGED_KTS  < <(git diff --cached --name-only --diff-filter=ACM | grep '\.kts$'  || true)
mapfile -t STAGED_XML  < <(git diff --cached --name-only --diff-filter=ACM | grep '\.xml$'  || true)
mapfile -t STAGED_ALL  < <(git diff --cached --name-only --diff-filter=ACM || true)

HAS_JAVA=${#STAGED_JAVA[@]}
HAS_ANDROID=$(( ${#STAGED_JAVA[@]} + ${#STAGED_KT[@]} + ${#STAGED_KTS[@]} + ${#STAGED_XML[@]} ))

# ── Google Java Format ────────────────────────────────────────────────────
if (( HAS_JAVA > 0 )); then
    step "检查 Java 代码格式 (google-java-format)"
    
    if ! command -v google-java-format &> /dev/null; then
        warn "google-java-format 未安装，跳过格式化检查"
        warn "安装: brew install google-java-format"
        warn "      或从 https://github.com/google/google-java-format 下载"
    else
        FORMAT_PASS=true
        for file in "${STAGED_JAVA[@]}"; do
            if [[ ! -f "$file" ]]; then continue; fi
            if ! google-java-format --dry-run --set-exit-if-changed "$file" &> /dev/null; then
                echo "     格式错误: $file"
                echo "     修复命令: google-java-format --replace '$file'"
                FORMAT_PASS=false
                OVERALL_PASS=false
            fi
        done
        [[ "$FORMAT_PASS" == "true" ]] && pass "Java 代码格式检查通过"
    fi
fi

# ── Android Lint ──────────────────────────────────────────────────────────
# 默认禁用（太慢），设置 RUN_LINT=1 可手动启用，或在 CI 中运行
if (( HAS_ANDROID > 0 )) && [[ "${RUN_LINT:-0}" == "1" ]]; then
    step "运行 Android Lint (lintDebug)"
    
    GRADLEW="$REPO_ROOT/gradlew"
    if [[ ! -f "$GRADLEW" ]]; then
        warn "未找到 gradlew，跳过 Lint 检查"
    else
        cd "$REPO_ROOT"
        LINT_PASS=true
        if ! ./gradlew lintDebug --quiet 2>&1; then
            fail "Lint 检查失败"
            echo "     查看报告: app/build/reports/lint-results-debug.html"
            LINT_PASS=false
        fi
        [[ "$LINT_PASS" == "true" ]] && pass "Lint 检查通过"
    fi
elif (( HAS_ANDROID > 0 )); then
    # Lint 默认跳过，提示在 CI 运行
    echo "> Lint 检查已跳过 (在 CI 中运行，或设置 RUN_LINT=1 本地启用)"
fi

# ── Checkstyle ────────────────────────────────────────────────────────────
# 仅在有配置文件时启用；与 google-java-format 互补（关注命名/业务规范）
CHECKSTYLE_CONFIG="$REPO_ROOT/config/checkstyle/checkstyle.xml"
if (( HAS_JAVA > 0 )) && [[ -f "$CHECKSTYLE_CONFIG" ]]; then
    step "运行 Checkstyle"
    
    if ! command -v checkstyle &> /dev/null; then
        warn "checkstyle 未安装，跳过检查"
        warn "安装: brew install checkstyle"
    else
        CS_PASS=true
        for file in "${STAGED_JAVA[@]}"; do
            if [[ ! -f "$file" ]]; then continue; fi
            if ! checkstyle -c "$CHECKSTYLE_CONFIG" "$file" &> /dev/null; then
                echo "     Checkstyle 错误: $file"
                CS_PASS=false
                OVERALL_PASS=false
            fi
        done
        [[ "$CS_PASS" == "true" ]] && pass "Checkstyle 检查通过"
    fi
fi

# ── 敏感信息检测（只扫描新增行）──────────────────────────────────────────
if (( ${#STAGED_ALL[@]} > 0 )); then
    step "检查敏感信息（仅扫描新增行）"
    
    # 只检查 diff 中以 + 开头的新增行，避免误报历史代码
    SENSITIVE_PATTERNS=(
        'password\s*=\s*["'"'"']\S+["'"'"']'
        'api_key\s*=\s*["'"'"']\S+["'"'"']'
        'secret\s*=\s*["'"'"']\S+["'"'"']'
        'token\s*=\s*["'"'"']\S+["'"'"']'
        'key\s*=\s*["'"'"'][A-Za-z0-9_/+]{20,}["'"'"']'
    )
    
    SENS_PASS=true
    for file in "${STAGED_ALL[@]}"; do
        # 跳过示例/模板文件
        if [[ "$file" == *.example || "$file" == *.sample || "$file" == *.template ]]; then
            continue
        fi
        
        # 从暂存区提取该文件的新增行（+开头，排除 diff 头部的 +++ 行）
        NEW_LINES=$(git diff --cached -U0 -- "$file" \
                    | grep '^+' \
                    | grep -v '^+++' || true)
        
        if [[ -z "$NEW_LINES" ]]; then continue; fi
        
        for pattern in "${SENSITIVE_PATTERNS[@]}"; do
            if echo "$NEW_LINES" | grep -Eiq "$pattern"; then
                echo "     可能含敏感信息: $file"
                echo "     请将密码/密钥/token 移至环境变量或 secrets 管理工具"
                SENS_PASS=false
                OVERALL_PASS=false
                break  # 同一文件只报一次
            fi
        done
    done
    
    [[ "$SENS_PASS" == "true" ]] && pass "未发现敏感信息"
fi

# ── 最终结果 ──────────────────────────────────────────────────────────────
echo ""
if [[ "$OVERALL_PASS" == "false" ]]; then
    echo "========================================="
    echo "❌  Pre-commit 检查失败，提交已中止"
    echo "========================================="
    echo "请修复上述错误后重新提交"
    echo "如需跳过检查（不推荐）: git commit --no-verify"
    exit 1
fi

echo "✅  所有 pre-commit 检查通过"
HOOK

chmod +x "$HOOK_FILE"

echo "✓ 钩子安装成功: $HOOK_FILE"
echo ""
echo "已安装的检查项:"
echo "  • Google Java Format  — Java 代码格式化（需安装 google-java-format）"
echo "  • Android Lint        — 默认跳过；设置 RUN_LINT=1 本地启用，建议在 CI 运行"
echo "  • Checkstyle          — 有 config/checkstyle/checkstyle.xml 时自动启用"
echo "  • 敏感信息检测        — 仅扫描新增行，减少误报"
echo ""
echo "提示: 重新运行 './precommit-setup.sh' 可重新安装钩子"