#!/usr/bin/env bash
set -euo pipefail

: "${APP_NAME:?APP_NAME is required}"
: "${DISPLAY_NAME:?DISPLAY_NAME is required}"
: "${VERSION:?VERSION is required}"
: "${ARCH_NAME:?ARCH_NAME is required}"
: "${BUILD_DIR:?BUILD_DIR is required}"
: "${DIST_DIR:?DIST_DIR is required}"
: "${APP_DIR:?APP_DIR is required}"
: "${DMG_PATH:?DMG_PATH is required}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found: $APP_DIR" >&2
  exit 1
fi

DMG_ROOT="$BUILD_DIR/dmg-root"
VOLUME_NAME="$DISPLAY_NAME"
TMP_DMG="$DMG_PATH.tmp.dmg"

case "$ARCH_NAME" in
  arm64)
    ARCH_LABEL="Apple Silicon Mac (arm64)"
    ;;
  x86_64)
    ARCH_LABEL="Intel Mac (x86_64)"
    ;;
  *)
    ARCH_LABEL="macOS ($ARCH_NAME)"
    ;;
esac

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT" "$DIST_DIR"

ditto "$APP_DIR" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

# Reuse the built app's reviewed Skill, including the root-script overrides.
COMPANION_SOURCE="$APP_DIR/Contents/Resources/CompanionSkill"
COMPANION_DEST="$DMG_ROOT/Companion Skill/multi-agent-management"
python3 - "$COMPANION_SOURCE" "$COMPANION_DEST" <<'PY'
import pathlib, runpy, shutil, subprocess, sys
source, destination = map(pathlib.Path, sys.argv[1:])
if not source.is_dir() or source.is_symlink():
    raise SystemExit('Missing reviewed app CompanionSkill resources')
definition = runpy.run_path('scripts/prepare-companion-resources.py')
public = definition['ROOT'] / '.agents/skills/multi-agent-management'
validated = []
for relative in definition['SKILL_FILES']:
    bundled = source / relative
    reviewed = definition['SKILL_SOURCE_OVERRIDES'].get(relative, public / relative)
    if (not bundled.is_file() or bundled.is_symlink()
            or any((source / parent).is_symlink() for parent in pathlib.Path(relative).parents)
            or not reviewed.is_file() or reviewed.is_symlink()):
        raise SystemExit(f'Missing reviewed companion Skill file: {relative}')
    if subprocess.run(['/usr/bin/cmp', '-s', str(reviewed), str(bundled)]).returncode:
        raise SystemExit(f'App companion Skill differs from reviewed source: {relative}')
    validated.append((relative, bundled))
for relative, bundled in validated:
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(bundled, target)
PY
install -m 644 LICENSE "$DMG_ROOT/Companion Skill/LICENSE"

cat > "$DMG_ROOT/README.txt" <<README
${DISPLAY_NAME} ${VERSION}
适用机型: ${ARCH_LABEL}

安装:
1. 将 ${APP_NAME}.app 拖到 Applications 文件夹。
2. 打开 Applications 里的 ${DISPLAY_NAME}。
3. 如果 macOS 提示来自互联网下载，请在系统设置 > 隐私与安全性中允许打开。

依赖:
- macOS 13 或更新版本。
- 本机已安装并登录 Codex。
- Codex 至少使用过一次，以便生成 ~/.codex/state_5.sqlite。

配套 Skill（可选）:
- Companion Skill 文件夹附多账号调度 Skill、脚本与中文使用说明。
- 已安装同名 Skill 时先比较差异并备份，保留个人 config；不要直接覆盖账号映射。
- 公开配置仅含停用示例；安装 Skill 不会自动配置 Hub 或启动任务。

权限与提醒:
- 新用户默认使用 ⌘U 显示/隐藏主窗口；已有快捷键设置保留。
- 菜单栏图标可以打开 Runtime 浮窗、主窗口、设置或退出应用。
- 重置消息默认开启，不消耗账号额度；macOS 提醒需系统允许通知。
- 自动化中心可查看消息或关闭接收；飞书是可选转发，不是必要配置。

隐私:
- 本应用读取 Codex app-server、~/.codex、独立账号目录和可选 ~/.claude 的本地数据。
- 认证内容只用于本机身份校验和用户启用的账号切换，不显示、不记录、不随诊断上传。
- 飞书开关与 Webhook 配置分别管理；配置并启用后只发送脱敏事件及公开重置消息。
README

rm -f "$DMG_PATH" "$TMP_DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$TMP_DMG"

mv "$TMP_DMG" "$DMG_PATH"

if [[ -n "${DMG_SIGN_IDENTITY:-}" && "${DMG_SIGN_IDENTITY:-}" != "-" ]]; then
  codesign --force --timestamp --sign "$DMG_SIGN_IDENTITY" "$DMG_PATH"
fi

hdiutil verify "$DMG_PATH"
echo "Created $DMG_PATH"
