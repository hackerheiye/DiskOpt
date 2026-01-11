#!/bin/bash
# 硬盘IO&寿命优化工具（保留历史输出版）
# 核心原则：仅修改ext4/xfs/btrfs分区，FAT/vfat/NTFS分区完全保持原样
# 适配：CentOS 7+/Ubuntu 20.04+/Anolis OS/Debian 10+，兼容HDD/SSD/NVMe
# 特性：移除clear命令，保留终端历史输出，增强可读性

# ===================== 基础配置（安全兜底） =====================
set -euo pipefail
IFS=$'\n\t'

# 颜色定义（兼容所有终端）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 备份/日志配置（自动保留3次历史备份）
BACKUP_DIR="${HOME}/.disk-optimize-backups"
CRON_SCRIPT="/root/.io_optimize_cron.sh"
CRON_LOG="/var/log/io_optimize_cron.log"
CHECK_INTERVAL=10  # 定时任务检测间隔（分钟）
TEMP_FILE="${BACKUP_DIR}/compat_partitions.tmp"

# 命令全路径（避免环境变量缺失）
MKDIR="/usr/bin/mkdir"
MOUNT="/usr/bin/mount"
GREP="/usr/bin/grep"
AWK="/usr/bin/awk"
SED="/usr/bin/sed"
CP="/usr/bin/cp"
LS="/usr/bin/ls"
TAIL="/usr/bin/tail"
RM="/usr/bin/rm"
ECHO="/usr/bin/echo"
BLKID="/usr/bin/blkid"
SYSTEMCTL="/usr/bin/systemctl"
CHMOD="/usr/bin/chmod"
TOUCH="/usr/bin/touch"
CRONTAB="/usr/bin/crontab"
CAT="/usr/bin/cat"
HDPARM="/usr/sbin/hdparm"
UNAME="/usr/bin/uname"
CUT="/usr/bin/cut"
HEAD="/usr/bin/head"
XARGS="/usr/bin/xargs"
SLEEP="/usr/bin/sleep"
DIFF="/usr/bin/diff"
TR="/usr/bin/tr"
DATE="/usr/bin/date"
ID="/usr/bin/id"
BASENAME="/usr/bin/basename"

# 全局变量
COMPAT_FS=("ext2" "ext3" "ext4" "xfs" "btrfs")  # 支持优化的文件系统
SKIP_FS=("vfat" "fat" "fat32" "ntfs" "exfat")    # 跳过的文件系统（保持原样）
SSD_DEVICES=()
HDD_DEVICES=()
TEMP_ONLY=0  # 0=永久优化 1=临时优化
DISTRO=$(${AWK} -F= '/^NAME/{print $2}' /etc/os-release 2>/dev/null | ${TR} -d '"' | ${AWK} '{print tolower($1)}' || ${ECHO} "unknown")
KERNEL_VER=$(${UNAME} -r 2>/dev/null | ${AWK} -F. '{print $1$2}' || ${ECHO} "0")

# ===================== 核心检测函数 =====================
# 检测硬盘类型（SSD/HDD）
detect_disk_type() {
    ${ECHO} -e "\n${BLUE}[检测] 识别硬盘类型...${NC}"
    SSD_DEVICES=()
    HDD_DEVICES=()

    for dev in /sys/block/*; do
        dev_name=$(${ECHO} "${dev}" | ${AWK} -F '/' '{print $NF}')
        # 跳过虚拟设备（增强匹配规则，兼容更多环境）
        if [[ "${dev_name}" =~ ^loop|^ram|^dm-|^sr|^fd|^zram|^md|^md0 ]]; then
            continue
        fi
        # 判断是否为旋转设备（0=SSD，1=HDD）
        rotational=$(cat "${dev}/queue/rotational" 2>/dev/null || ${ECHO} 1)
        if [[ "${rotational}" -eq 0 ]]; then
            SSD_DEVICES+=("${dev_name}")
        else
            HDD_DEVICES+=("${dev_name}")
        fi
    done

    ${ECHO} -e "  ✅ SSD设备：${SSD_DEVICES[*]:-无}"
    ${ECHO} -e "  ✅ HDD设备：${HDD_DEVICES[*]:-无}"

    if [[ ${#SSD_DEVICES[@]} -eq 0 && ${#HDD_DEVICES[@]} -eq 0 ]]; then
        ${ECHO} -e "${RED}错误：未检测到物理硬盘（可能是容器环境），脚本退出${NC}"
        exit 1
    fi
}

# 检测分区&文件系统类型（核心：区分兼容/跳过分区）
detect_partitions() {
    ${ECHO} -e "\n${BLUE}[检测] 识别分区及文件系统类型...${NC}"
    ${MKDIR} -p "${BACKUP_DIR}" 2>/dev/null || true
    ${RM} -f "${TEMP_FILE}" 2>/dev/null || true
    ${TOUCH} "${TEMP_FILE}" 2>/dev/null || true

    # 遍历已挂载的分区
    mounted_partitions=$(${MOUNT} | ${GREP} -E '^/dev/' | ${AWK} '{print $1,$3,$5}')

    while IFS=' ' read -r dev mount_point fs_type; do
        if [[ -z "${dev}" || -z "${fs_type}" ]]; then
            continue
        fi
        # 统一转为小写，避免大小写问题
        fs_type_lower=$(${ECHO} "${fs_type}" | ${TR} '[:upper:]' '[:lower:]')

        # 判断是否跳过（完全保持原样）
        if [[ " ${SKIP_FS[*]} " =~ " ${fs_type_lower} " ]]; then
            ${ECHO} -e "  🚫 跳过分区：${dev} (${mount_point}) | 文件系统：${fs_type}（不支持优化，保持原样）"
            continue
        fi

        # 仅处理兼容分区
        if [[ " ${COMPAT_FS[*]} " =~ " ${fs_type_lower} " ]]; then
            ${ECHO} -e "  ✅ 兼容分区：${dev} (${mount_point}) | 文件系统：${fs_type}（支持优化）"
            # 记录兼容分区（用于后续优化）
            ${ECHO} "${dev}:${mount_point}:${fs_type}" >> "${TEMP_FILE}"
            continue
        fi

        # 其他文件系统（默认跳过）
        ${ECHO} -e "  ⚠️  未知分区：${dev} (${mount_point}) | 文件系统：${fs_type}（跳过，保持原样）"
    done <<< "${mounted_partitions}"

    # 强制跳过/boot/efi（常见FAT分区，避免误改）
    if ${MOUNT} | ${GREP} -q "/boot/efi"; then
        efi_dev=$(${MOUNT} | ${GREP} "/boot/efi" | ${AWK} '{print $1}')
        ${ECHO} -e "  🚫 跳过分区：${efi_dev} (/boot/efi) | 文件系统：vfat（EFI分区，保持原样）"
    fi

    # 若无兼容分区，提示但不退出
    if [[ ! -s "${TEMP_FILE}" ]]; then
        ${ECHO} -e "${YELLOW}提示：未检测到支持优化的分区（ext4/xfs等），仅执行基础检测${NC}"
    fi
}

# 备份配置文件（fstab/grub，自动清理旧备份）
safe_backup() {
    local backup_tag="${1:-manual}"
    ${MKDIR} -p "${BACKUP_DIR}" 2>/dev/null || true

    ${ECHO} -e "\n${BLUE}[备份] 开始备份关键配置...${NC}"
    # 备份fstab（增强权限检查）
    if [[ ! -w "/etc/fstab" ]]; then
        ${ECHO} -e "${RED}错误：无/etc/fstab写入权限，请以root运行${NC}"
        exit 1
    fi
    fstab_backup="${BACKUP_DIR}/fstab.backup_${backup_tag}_$(${DATE} +%Y%m%d_%H%M%S)"
    ${CP} -pf /etc/fstab "${fstab_backup}" 2>/dev/null || {
        ${ECHO} -e "${RED}错误：备份fstab失败，请检查权限${NC}"
        exit 1
    }
    ${ECHO} -e "  ✅ fstab已备份至：${fstab_backup}"

    # 备份grub（容错：部分系统无grub配置）
    if [[ -f /etc/default/grub && -w /etc/default/grub ]]; then
        grub_backup="${BACKUP_DIR}/grub.backup_${backup_tag}_$(${DATE} +%Y%m%d_%H%M%S)"
        ${CP} -pf /etc/default/grub "${grub_backup}" 2>/dev/null || true
        ${ECHO} -e "  ✅ grub已备份至：${grub_backup}"
    fi

    # 保留最近3次备份，清理旧备份（增强容错）
    for cfg_type in fstab grub; do
        backup_files=$(${LS} -t "${BACKUP_DIR}/${cfg_type}.backup_"* 2>/dev/null)
        if [[ -n "${backup_files}" ]]; then
            ${ECHO} "${backup_files}" | ${TAIL} -n +4 | ${XARGS} -I {} ${RM} -f {} 2>/dev/null || true
        fi
    done
    ${ECHO} -e "${GREEN}✅ 配置备份完成（自动保留最近3次）${NC}"
}

# ===================== 核心优化函数 =====================
# 优化fstab（仅对兼容分区添加参数，修复路径转义问题）
optimize_fstab() {
    safe_backup "fstab"
    ${ECHO} -e "\n${BLUE}[优化] 仅修改兼容分区的fstab参数（跳过FAT/NTFS）...${NC}"

    # 遍历兼容分区
    while IFS=':' read -r dev mount_point fs_type; do
        if [[ -z "${dev}" ]]; then
            continue
        fi

        # 转义分区路径中的/（修复sed匹配失败问题）
        dev_escaped="${dev//\//\\/}"
        
        # 1. 先清理旧的重复参数（避免叠加）
        ${SED} -i "/^${dev_escaped}/ s/ noatime//g" /etc/fstab 2>/dev/null || true
        ${SED} -i "/^${dev_escaped}/ s/ discard=async//g" /etc/fstab 2>/dev/null || true
        
        # 2. 添加noatime（减少IO）
        if ! ${GREP} -q "^${dev_escaped}.*noatime" /etc/fstab 2>/dev/null; then
            ${SED} -i "/^${dev_escaped}/ s/\(defaults\|rw\|ro\)/\1,noatime/" /etc/fstab 2>/dev/null || {
                ${ECHO} -e "${YELLOW}  ⚠️  分区${dev}：已添加noatime，跳过重复操作${NC}"
                continue
            }
        fi
        
        # 3. SSD分区额外添加discard=async（异步TRIM，内核4.18+）
        if [[ " ${SSD_DEVICES[*]} " =~ $(basename "${dev}") && "${KERNEL_VER}" -ge 418 ]]; then
            if ! ${GREP} -q "^${dev_escaped}.*discard=async" /etc/fstab 2>/dev/null; then
                ${SED} -i "/^${dev_escaped}/ s/\(defaults\|rw\|ro\)/\1,discard=async/" /etc/fstab 2>/dev/null || true
                ${ECHO} -e "  ✅ 分区${dev}：添加noatime+discard=async（SSD优化）"
            fi
        else
            ${ECHO} -e "  ✅ 分区${dev}：添加noatime（HDD优化）"
        fi

        # 立即重新挂载该分区（生效参数，增强容错）
        if ${MOUNT} -o remount "${mount_point}" 2>/dev/null; then
            ${ECHO} -e "  ✅ 分区${dev}：重新挂载成功，参数立即生效"
        else
            ${ECHO} -e "${YELLOW}  ⚠️  分区${dev}：重新挂载失败（可能只读），重启后生效${NC}"
        fi
    done < "${TEMP_FILE}"

    # 校验fstab语法（关键：避免配置错误）
    if ${MOUNT} -a 2>/dev/null; then
        ${ECHO} -e "${GREEN}✅ fstab语法校验通过，所有兼容分区优化完成${NC}"
    else
        ${ECHO} -e "${RED}错误：fstab修改后语法错误！自动回滚备份${NC}"
        latest_backup=$(${LS} -t "${BACKUP_DIR}/fstab.backup_"* 2>/dev/null | ${HEAD} -n1)
        if [[ -f "${latest_backup}" ]]; then
            ${CP} -pf "${latest_backup}" /etc/fstab 2>/dev/null || true
        fi
        exit 1
    fi
}

# 优化IO调度器（临时+永久可选，增强容错）
optimize_scheduler() {
    ${ECHO} -e "\n${PURPLE}===================== IO调度器优化类型 =====================${NC}"
    ${ECHO} -e "1. 临时优化（立即生效，重启后失效，自动添加定时任务恢复）"
    ${ECHO} -e "2. 永久优化（修改grub，需重启生效）"
    read -p "请选择优化类型（1/2）：" sch_choice
    case "${sch_choice}" in
        1) TEMP_ONLY=1 ;;
        2) TEMP_ONLY=0 ;;
        *) ${ECHO} -e "${RED}输入错误，默认选择临时优化${NC}"; TEMP_ONLY=1 ;;
    esac

    safe_backup "scheduler"
    ${ECHO} -e "\n${BLUE}[优化] 配置IO调度器...${NC}"
    GRUB_FILE="/etc/default/grub"

    # 临时生效（立即生效，增强容错）
    for dev in "${SSD_DEVICES[@]}"; do
        optimal="none"
        if [[ "${dev}" != "nvme"* ]]; then
            optimal="noop"
        fi
        scheduler_path="/sys/block/${dev}/queue/scheduler"
        if [[ -w "${scheduler_path}" ]]; then
            ${ECHO} "${optimal}" > "${scheduler_path}" 2>/dev/null || true
            current=$(${CAT} "${scheduler_path}" 2>/dev/null | ${AWK} -F'[][]' '{print $2}')
            ${ECHO} -e "  ✅ SSD(${dev})：调度器设为${current}（临时生效）"
        else
            ${ECHO} -e "${YELLOW}  ⚠️  SSD(${dev})：无调度器修改权限（系统限制）${NC}"
        fi
    done

    for dev in "${HDD_DEVICES[@]}"; do
        optimal="mq-deadline"
        scheduler_path="/sys/block/${dev}/queue/scheduler"
        if [[ -w "${scheduler_path}" ]]; then
            ${ECHO} "${optimal}" > "${scheduler_path}" 2>/dev/null || true
            current=$(${CAT} "${scheduler_path}" 2>/dev/null | ${AWK} -F'[][]' '{print $2}')
            ${ECHO} -e "  ✅ HDD(${dev})：调度器设为${current}（临时生效）"
        else
            ${ECHO} -e "${YELLOW}  ⚠️  HDD(${dev})：无调度器修改权限（系统限制）${NC}"
        fi
    done

    # 永久生效（写入grub，需重启）
    if [[ "${TEMP_ONLY}" -eq 0 ]]; then
        # 确保GRUB_CMDLINE_LINUX字段存在
        if ! ${GREP} -q "^GRUB_CMDLINE_LINUX=" "${GRUB_FILE}" 2>/dev/null && [[ -w "${GRUB_FILE}" ]]; then
            ${ECHO} 'GRUB_CMDLINE_LINUX=""' >> "${GRUB_FILE}"
        fi

        # 清理旧参数
        ${SED} -i "s/ elevator=[a-zA-Z0-9_-]*//g" "${GRUB_FILE}" 2>/dev/null || true
        # 添加新参数
        if [[ ${#SSD_DEVICES[@]} -gt 0 && ${#HDD_DEVICES[@]} -eq 0 ]]; then
            ${SED} -i "/^GRUB_CMDLINE_LINUX=/ s/\"$/ elevator=none\"/" "${GRUB_FILE}" 2>/dev/null || true
            ${ECHO} -e "  ✅ 永久调度器：elevator=none（仅SSD，需重启生效）"
        elif [[ ${#HDD_DEVICES[@]} -gt 0 ]]; then
            ${SED} -i "/^GRUB_CMDLINE_LINUX=/ s/\"$/ elevator=mq-deadline\"/" "${GRUB_FILE}" 2>/dev/null || true
            ${ECHO} -e "  ✅ 永久调度器：elevator=mq-deadline（含HDD，需重启生效）"
        fi

        # 更新grub（适配不同发行版，增强容错）
        if [[ "${DISTRO}" =~ centos|anolis|rhel|rocky ]]; then
            grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || {
                ${ECHO} -e "${YELLOW}  ⚠️  GRUB更新失败，请手动执行grub2-mkconfig${NC}"
            }
        elif [[ "${DISTRO}" =~ ubuntu|debian|deepin ]]; then
            update-grub >/dev/null 2>&1 || {
                ${ECHO} -e "${YELLOW}  ⚠️  GRUB更新失败，请手动执行update-grub${NC}"
            }
        fi
        ${ECHO} -e "${GREEN}✅ IO调度器永久配置完成（需重启生效）${NC}"
    else
        # 临时优化：添加定时任务自动恢复
        generate_cron_script
        add_cron_job
        ${ECHO} -e "${GREEN}✅ IO调度器临时配置完成，定时任务每${CHECK_INTERVAL}分钟检测恢复${NC}"
    fi
}

# 优化TRIM（仅SSD，增强容错）
optimize_trim() {
    if [[ ${#SSD_DEVICES[@]} -eq 0 ]]; then
        ${ECHO} -e "${YELLOW}未检测到SSD，跳过TRIM配置${NC}"
        return 0
    fi

    safe_backup "trim"
    ${ECHO} -e "\n${BLUE}[优化] 配置SSD定时TRIM...${NC}"
    
    # 禁用实时discard（内核4.18+更推荐定时TRIM）
    while IFS=':' read -r dev mount_point fs_type; do
        if [[ -n "${dev}" ]]; then
            dev_escaped="${dev//\//\\/}"
            ${SED} -i "/^${dev_escaped}/ s/ discard//g" /etc/fstab 2>/dev/null || true
        fi
    done < "${TEMP_FILE}"

    # 自动安装fstrim（若缺失）
    if ! command -v fstrim >/dev/null 2>&1; then
        ${ECHO} -e "${YELLOW}未安装fstrim，开始自动安装...${NC}"
        if [[ "${DISTRO}" =~ centos|anolis|rhel ]]; then
            yum install -y util-linux >/dev/null 2>&1 || true
        else
            apt update >/dev/null 2>&1 && apt install -y util-linux >/dev/null 2>&1 || true
        fi
    fi

    # 启用定时TRIM（增强容错）
    ${SYSTEMCTL} enable --now fstrim.timer >/dev/null 2>&1 || {
        ${ECHO} -e "${YELLOW}  ⚠️  fstrim.timer启动失败，尝试手动启用${NC}"
        ${SYSTEMCTL} start fstrim.timer >/dev/null 2>&1 || true
    }
    
    if ${SYSTEMCTL} is-active fstrim.timer >/dev/null 2>&1; then
        cycle=$(${SYSTEMCTL} show fstrim.timer --property=OnCalendar --value 2>/dev/null || ${ECHO} "每周")
        ${ECHO} -e "  ✅ SSD TRIM：已启用定时任务（周期：${cycle}）"
    else
        ${ECHO} -e "${YELLOW}  ⚠️  SSD TRIM：定时任务启动失败，建议手动执行fstrim -a${NC}"
    fi
    ${ECHO} -e "${GREEN}✅ TRIM配置完成（立即生效，永久自启）${NC}"
}

# 优化预读大小（增强容错）
optimize_readahead() {
    safe_backup "readahead"
    ${ECHO} -e "\n${BLUE}[优化] 调整预读大小...${NC}"
    
    # SSD预读：256KB
    for dev in "${SSD_DEVICES[@]}"; do
        readahead_path="/sys/block/${dev}/queue/read_ahead_kb"
        if [[ -w "${readahead_path}" ]]; then
            ${ECHO} "256" > "${readahead_path}" 2>/dev/null || true
            current=$(${CAT} "${readahead_path}" 2>/dev/null)
            ${ECHO} -e "  ✅ SSD(${dev})：预读大小设为${current}KB"
        else
            ${ECHO} -e "${YELLOW}  ⚠️  SSD(${dev})：无预读修改权限（系统限制）${NC}"
        fi
    done
    
    # HDD预读：1024KB
    for dev in "${HDD_DEVICES[@]}"; do
        readahead_path="/sys/block/${dev}/queue/read_ahead_kb"
        if [[ -w "${readahead_path}" ]]; then
            ${ECHO} "1024" > "${readahead_path}" 2>/dev/null || true
            current=$(${CAT} "${readahead_path}" 2>/dev/null)
            ${ECHO} -e "  ✅ HDD(${dev})：预读大小设为${current}KB"
        else
            ${ECHO} -e "${YELLOW}  ⚠️  HDD(${dev})：无预读修改权限（系统限制）${NC}"
        fi
    done

    # 添加定时任务自动恢复
    generate_cron_script
    add_cron_job
    ${ECHO} -e "${GREEN}✅ 预读大小配置完成（立即生效，定时任务检测恢复）${NC}"
}

# 优化HDD电源管理APM（仅对HDD生效，增强容错）
optimize_hdd_apm() {
    if [[ ${#HDD_DEVICES[@]} -eq 0 ]]; then
        ${ECHO} -e "${YELLOW}未检测到HDD，跳过APM配置${NC}"
        return 0
    fi

    # 自动安装hdparm（增强容错）
    if [[ ! -x "${HDPARM}" ]]; then
        ${ECHO} -e "${YELLOW}未安装hdparm，开始自动安装...${NC}"
        if [[ "${DISTRO}" =~ centos|anolis|rhel ]]; then
            yum install -y hdparm >/dev/null 2>&1 || {
                ${ECHO} -e "${RED}  ❌ hdparm安装失败，请手动安装后重试${NC}"
                return 1
            }
        else
            apt update >/dev/null 2>&1 && apt install -y hdparm >/dev/null 2>&1 || {
                ${ECHO} -e "${RED}  ❌ hdparm安装失败，请手动安装后重试${NC}"
                return 1
            }
        fi
    fi

    safe_backup "hdd_apm"
    ${ECHO} -e "\n${BLUE}[优化] 配置HDD电源管理APM...${NC}"
    
    for dev in "${HDD_DEVICES[@]}"; do
        dev_path="/dev/${dev}"
        if [[ -b "${dev_path}" && -w "${dev_path}" ]]; then
            # 临时生效：设置APM级别128（平衡性能和功耗）
            ${HDPARM} -B 128 "${dev_path}" >/dev/null 2>&1 || {
                ${ECHO} -e "${YELLOW}  ⚠️  HDD(${dev})：APM设置失败（设备不支持）${NC}"
                continue
            }
            current=$(${HDPARM} -B "${dev_path}" 2>/dev/null | ${AWK} -F'=' '/APM_level/{gsub(/[^0-9]/,"",$2);print $2}')
            if [[ "${current}" -eq 128 ]]; then
                ${ECHO} -e "  ✅ HDD(${dev})：APM级别设为${current}（临时生效）"
            else
                ${ECHO} -e "${YELLOW}  ⚠️  HDD(${dev})：APM设置失败${NC}"
                continue
            fi

            # 永久生效：写入systemd或rc.local（增强适配）
            if [[ "${DISTRO}" =~ ubuntu|anolis|debian|deepin ]]; then
                # 创建systemd服务
                service_file="/etc/systemd/system/hdd-apm@${dev}.service"
                ${CAT} > "${service_file}" << EOF
[Unit]
Description=Set HDD APM level for %I
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${HDPARM} -B 128 /dev/%I
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
                ${SYSTEMCTL} daemon-reload >/dev/null 2>&1 || true
                ${SYSTEMCTL} enable --now "hdd-apm@${dev}.service" >/dev/null 2>&1 || true
                ${ECHO} -e "  ✅ HDD(${dev})：APM通过systemd永久生效"
            else
                # 写入rc.local（兼容老系统）
                if [[ ! -f /etc/rc.local ]]; then
                    ${ECHO} "#!/bin/bash" > /etc/rc.local
                    ${CHMOD} +x /etc/rc.local 2>/dev/null || true
                fi
                if ! ${GREP} -q "${HDPARM} -B 128 ${dev_path}" /etc/rc.local 2>/dev/null; then
                    ${ECHO} "${HDPARM} -B 128 ${dev_path}" >> /etc/rc.local
                fi
                ${ECHO} -e "  ✅ HDD(${dev})：APM写入rc.local永久生效"
            fi
        else
            ${ECHO} -e "${YELLOW}  ⚠️  HDD(${dev})：设备不可写（权限/不存在）${NC}"
        fi
    done

    # 添加定时任务自动恢复
    generate_cron_script
    add_cron_job
    ${ECHO} -e "${GREEN}✅ HDD APM配置完成（立即生效，定时任务检测恢复）${NC}"
}

# 启用blk-mq多核IO（适配多核CPU+NVMe，增强容错）
optimize_blkmq() {
    safe_backup "blkmq"
    ${ECHO} -e "\n${BLUE}[优化] 启用blk-mq多核IO...${NC}"
    GRUB_FILE="/etc/default/grub"

    # 跳过无grub权限的场景
    if [[ ! -w "${GRUB_FILE}" ]]; then
        ${ECHO} -e "${RED}错误：无${GRUB_FILE}写入权限${NC}"
        return 1
    fi

    # 确保GRUB_CMDLINE_LINUX字段存在
    if ! ${GREP} -q "^GRUB_CMDLINE_LINUX=" "${GRUB_FILE}"; then
        ${ECHO} 'GRUB_CMDLINE_LINUX=""' >> "${GRUB_FILE}"
    fi

    # 清理旧参数
    ${SED} -i 's/ blk-mq//g' "${GRUB_FILE}" 2>/dev/null || true
    # 添加新参数
    ${SED} -i '/^GRUB_CMDLINE_LINUX=/ s/"$/ blk-mq"/' "${GRUB_FILE}" 2>/dev/null || true

    # 更新grub（增强适配）
    if [[ "${DISTRO}" =~ centos|anolis|rhel|rocky ]]; then
        grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || {
            ${ECHO} -e "${YELLOW}  ⚠️  GRUB更新失败，请手动执行grub2-mkconfig${NC}"
        }
    elif [[ "${DISTRO}" =~ ubuntu|debian|deepin ]]; then
        update-grub >/dev/null 2>&1 || {
            ${ECHO} -e "${YELLOW}  ⚠️  GRUB更新失败，请手动执行update-grub${NC}"
        }
    fi

    if ${GREP} -q "blk-mq" "${GRUB_FILE}" 2>/dev/null; then
        ${ECHO} -e "${GREEN}✅ blk-mq已添加到grub（需重启生效）${NC}"
    else
        ${ECHO} -e "${YELLOW}  ⚠️  blk-mq添加失败，请手动检查${GRUB_FILE}${NC}"
    fi
}

# ===================== 定时任务函数 =====================
# 生成定时检测脚本（增强容错）
generate_cron_script() {
    local ssd_devs="${SSD_DEVICES[*]:-}"
    local hdd_devs="${HDD_DEVICES[*]:-}"
    
    # 确保目录权限
    ${MKDIR} -p "$(${DIRNAME} "${CRON_SCRIPT}")" 2>/dev/null || true
    
    ${CAT} > "${CRON_SCRIPT}" << EOF
#!/bin/bash
set -euo pipefail
IFS=\$'\n\t'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 定义命令变量
ECHO="/usr/bin/echo"
CAT="/usr/bin/cat"
AWK="/usr/bin/awk"
GREP="/usr/bin/grep"
DATE="/usr/bin/date"

# 定义变量
SSD_DEVICES=($ssd_devs)
HDD_DEVICES=($hdd_devs)
HDPARM="${HDPARM}"
CRON_LOG="${CRON_LOG}"

# 日志函数
log() {
    \${ECHO} "[\$(date +%Y-%m-%d\ %H:%M:%S)] \$1" >> "\${CRON_LOG}"
}

# 错误处理函数
error_handler() {
    log "错误：\$1"
}

trap 'error_handler "\$BASH_COMMAND failed with exit code \$?"' ERR

# 检测并恢复IO调度器
log "检测IO调度器状态"
for dev in "\${SSD_DEVICES[@]}"; do
    optimal="none"
    if [[ "\${dev}" != "nvme"* ]]; then
        optimal="noop"
    fi
    scheduler_path="/sys/block/\${dev}/queue/scheduler"
    if [[ -w "\${scheduler_path}" ]]; then
        current=\$(\${CAT} "\${scheduler_path}" 2>/dev/null | \${AWK} -F'[][]' '{print \$2}')
        if [[ "\${current}" != "\${optimal}" ]]; then
            log "SSD(\${dev})调度器异常：\${current} → \${optimal}"
            \${ECHO} "\${optimal}" > "\${scheduler_path}" 2>/dev/null || log "SSD(\${dev})调度器设置失败"
        fi
    fi
done

for dev in "\${HDD_DEVICES[@]}"; do
    optimal="mq-deadline"
    scheduler_path="/sys/block/\${dev}/queue/scheduler"
    if [[ -w "\${scheduler_path}" ]]; then
        current=\$(\${CAT} "\${scheduler_path}" 2>/dev/null | \${AWK} -F'[][]' '{print \$2}')
        if [[ "\${current}" != "\${optimal}" ]]; then
            log "HDD(\${dev})调度器异常：\${current} → \${optimal}"
            \${ECHO} "\${optimal}" > "\${scheduler_path}" 2>/dev/null || log "HDD(\${dev})调度器设置失败"
        fi
    fi
done

# 检测并恢复预读大小
log "检测预读大小状态"
for dev in "\${SSD_DEVICES[@]}"; do
    readahead_path="/sys/block/\${dev}/queue/read_ahead_kb"
    if [[ -w "\${readahead_path}" ]]; then
        current=\$(\${CAT} "\${readahead_path}" 2>/dev/null)
        if [[ "\${current}" != "256" ]]; then
            log "SSD(\${dev})预读异常：\${current}KB → 256KB"
            \${ECHO} "256" > "\${readahead_path}" 2>/dev/null || log "SSD(\${dev})预读设置失败"
        fi
    fi
done

for dev in "\${HDD_DEVICES[@]}"; do
    readahead_path="/sys/block/\${dev}/queue/read_ahead_kb"
    if [[ -w "\${readahead_path}" ]]; then
        current=\$(\${CAT} "\${readahead_path}" 2>/dev/null)
        if [[ "\${current}" != "1024" ]]; then
            log "HDD(\${dev})预读异常：\${current}KB → 1024KB"
            \${ECHO} "1024" > "\${readahead_path}" 2>/dev/null || log "HDD(\${dev})预读设置失败"
        fi
    fi
done

# 检测并恢复HDD APM
log "检测HDD APM状态"
if [[ -x "\${HDPARM}" ]]; then
    for dev in "\${HDD_DEVICES[@]}"; do
        dev_path="/dev/\${dev}"
        if [[ -b "\${dev_path}" && -w "\${dev_path}" ]]; then
            current=\$(\${HDPARM} -B "\${dev_path}" 2>/dev/null | \${AWK} -F'=' '/APM_level/{gsub(/[^0-9]/,"",\$2);print \$2}')
            if [[ "\${current}" != "128" && -n "\${current}" ]]; then
                log "HDD(\${dev})APM异常：\${current} → 128"
                \${HDPARM} -B 128 "\${dev_path}" >/dev/null 2>&1 || log "HDD(\${dev})APM设置失败"
            fi
        fi
    done
fi

log "检测完成"
EOF

    ${CHMOD} 700 "${CRON_SCRIPT}" 2>/dev/null || true
    ${TOUCH} "${CRON_LOG}" 2>/dev/null || true
    ${CHMOD} 600 "${CRON_LOG}" 2>/dev/null || true
}

# 添加定时任务（增强容错）
add_cron_job() {
    # 先移除旧任务
    if ${CRONTAB} -l 2>/dev/null; then
        ${CRONTAB} -l 2>/dev/null | ${GREP} -v "${CRON_SCRIPT}" | ${CRONTAB} - 2>/dev/null || true
    fi
    # 添加新任务
    (${CRONTAB} -l 2>/dev/null || true; ${ECHO} "*/${CHECK_INTERVAL} * * * * ${CRON_SCRIPT} >> ${CRON_LOG} 2>&1") | ${CRONTAB} - 2>/dev/null
    if ${CRONTAB} -l 2>/dev/null | ${GREP} -q "${CRON_SCRIPT}"; then
        ${ECHO} -e "  ✅ 定时任务已添加：每${CHECK_INTERVAL}分钟检测一次（日志：${CRON_LOG}）"
    else
        ${ECHO} -e "${YELLOW}  ⚠️  定时任务添加失败，请手动执行crontab -e添加${NC}"
    fi
}

# 移除定时任务
remove_cron_job() {
    if ${CRONTAB} -l 2>/dev/null | ${GREP} -q "${CRON_SCRIPT}"; then
        ${CRONTAB} -l 2>/dev/null | ${GREP} -v "${CRON_SCRIPT}" | ${CRONTAB} - 2>/dev/null || true
        ${RM} -f "${CRON_SCRIPT}" "${CRON_LOG}" 2>/dev/null || true
        ${ECHO} -e "${GREEN}✅ 定时任务已移除${NC}"
    else
        ${ECHO} -e "${YELLOW}⚠️  未检测到定时任务，无需移除${NC}"
    fi
}

# ===================== 配置回滚&状态查看 =====================
# 回滚配置到最近备份
rollback_config() {
    ${ECHO} -e "\n${BLUE}[回滚] 选择要回滚的备份版本...${NC}"
    
    # 获取fstab备份列表（最近3次）
    ${ECHO} -e "\n${YELLOW}fstab备份列表：${NC}"
    fstab_backups=$(${LS} -t "${BACKUP_DIR}/fstab.backup_"* 2>/dev/null | ${HEAD} -n3)
    if [[ -z "${fstab_backups}" ]]; then
        ${ECHO} -e "${RED}  无fstab备份文件${NC}"
        return 1
    fi
    
    local index=1
    declare -A fstab_backup_map
    while IFS= read -r backup_file; do
        if [[ -f "${backup_file}" ]]; then
            backup_name=$(${BASENAME} "${backup_file}")
            backup_time=$(${ECHO} "${backup_name}" | ${SED} -E 's/.*_([0-9]{8}_[0-9]{6}).*/\1/' | ${SED} 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
            ${ECHO} -e "  ${index}. ${backup_name} (${backup_time})"
            fstab_backup_map[${index}]="${backup_file}"
            index=$((index + 1))
        fi
    done <<< "${fstab_backups}"
    
    # 获取grub备份列表（最近3次）
    ${ECHO} -e "\n${YELLOW}grub备份列表：${NC}"
    grub_backups=$(${LS} -t "${BACKUP_DIR}/grub.backup_"* 2>/dev/null | ${HEAD} -n3)
    if [[ -z "${grub_backups}" ]]; then
        ${ECHO} -e "  无grub备份文件"
    fi
    
    local grub_index=1
    declare -A grub_backup_map
    while IFS= read -r backup_file; do
        if [[ -f "${backup_file}" ]]; then
            backup_name=$(${BASENAME} "${backup_file}")
            backup_time=$(${ECHO} "${backup_name}" | ${SED} -E 's/.*_([0-9]{8}_[0-9]{6}).*/\1/' | ${SED} 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
            ${ECHO} -e "  ${grub_index}. ${backup_name} (${backup_time})"
            grub_backup_map[${grub_index}]="${backup_file}"
            grub_index=$((grub_index + 1))
        fi
    done <<< "${grub_backups}"
    
    # 选择要回滚的fstab版本
    ${ECHO} -e "\n${BLUE}请选择要回滚的fstab版本（1-$((index-1))，0跳过）：${NC}"
    read -p "fstab版本：" fstab_choice
    
    if [[ "${fstab_choice}" =~ ^[0-9]+$ ]] && [[ "${fstab_choice}" -ge 1 ]] && [[ "${fstab_choice}" -lt "${index}" ]]; then
        selected_fstab="${fstab_backup_map[${fstab_choice}]}"
        if [[ -f "${selected_fstab}" && -w "/etc/fstab" ]]; then
            ${CP} -pf "${selected_fstab}" /etc/fstab 2>/dev/null || {
                ${ECHO} -e "${RED}错误：回滚fstab失败${NC}"
                return 1
            }
            ${ECHO} -e "  ✅ fstab已回滚至：${selected_fstab}"
        else
            ${ECHO} -e "${RED}错误：fstab备份文件不存在或无写入权限${NC}"
        fi
    elif [[ "${fstab_choice}" != "0" ]]; then
        ${ECHO} -e "${YELLOW}无效选择，跳过fstab回滚${NC}"
    fi
    
    # 选择要回滚的grub版本
    if [[ -n "${grub_backups}" ]]; then
        ${ECHO} -e "\n${BLUE}请选择要回滚的grub版本（1-$((grub_index-1))，0跳过）：${NC}"
        read -p "grub版本：" grub_choice
        
        if [[ "${grub_choice}" =~ ^[0-9]+$ ]] && [[ "${grub_choice}" -ge 1 ]] && [[ "${grub_choice}" -lt "${grub_index}" ]]; then
            selected_grub="${grub_backup_map[${grub_choice}]}"
            if [[ -f "${selected_grub}" && -w "/etc/default/grub" ]]; then
                ${CP} -pf "${selected_grub}" /etc/default/grub 2>/dev/null || true
                # 更新grub
                if [[ "${DISTRO}" =~ centos|anolis|rhel ]]; then
                    grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
                else
                    update-grub >/dev/null 2>&1 || true
                fi
                ${ECHO} -e "  ✅ grub已回滚至：${selected_grub}（需重启生效）"
            else
                ${ECHO} -e "${RED}错误：grub备份文件不存在或无写入权限${NC}"
            fi
        elif [[ "${grub_choice}" != "0" ]]; then
            ${ECHO} -e "${YELLOW}无效选择，跳过grub回滚${NC}"
        fi
    fi

    # 移除定时任务
    ${ECHO} -e "\n${BLUE}是否移除定时检测任务？(y/n)：${NC}"
    read -p "选择：" remove_cron_choice
    if [[ "${remove_cron_choice}" == "y" || "${remove_cron_choice}" == "Y" ]]; then
        remove_cron_job
    fi

    ${ECHO} -e "${GREEN}✅ 配置回滚完成${NC}"
}

# 查看当前优化状态（保留历史输出，用分隔线替代clear）
show_status() {
    ${ECHO} -e "\n${PURPLE}===================== 当前硬盘优化状态 =====================${NC}"
    ${ECHO} -e "系统信息：${DISTRO} | 内核版本：$(${UNAME} -r) | 检测时间：$(${DATE} +%F" "%T)"
    ${ECHO} -e "SSD设备：${SSD_DEVICES[*]:-无} | HDD设备：${HDD_DEVICES[*]:-无}"
    ${ECHO} -e "============================================================"

    # 1. TRIM状态
    ${ECHO} -e "${BLUE}1. SSD定时TRIM${NC}"
    local fstrim_timer_file="/lib/systemd/system/fstrim.timer"
    if ${SYSTEMCTL} is-enabled fstrim.timer >/dev/null 2>&1; then
        if [[ -f "${fstrim_timer_file}" ]]; then
            cycle=$(${GREP} "^OnCalendar=" "${fstrim_timer_file}" 2>/dev/null | ${AWK} -F'=' '{print $2}')
            accuracy=$(${GREP} "^AccuracySec=" "${fstrim_timer_file}" 2>/dev/null | ${AWK} -F'=' '{print $2}')
            persistent=$(${GREP} "^Persistent=" "${fstrim_timer_file}" 2>/dev/null | ${AWK} -F'=' '{print $2}')
            delay=$(${GREP} "^RandomizedDelaySec=" "${fstrim_timer_file}" 2>/dev/null | ${AWK} -F'=' '{print $2}')
            ${ECHO} -e "   状态：${GREEN}已启用${NC}"
            ${ECHO} -e "   执行周期：${cycle}"
            ${ECHO} -e "   精度：${accuracy} | 持久化：${persistent} | 随机延迟：${delay}"
        else
            cycle=$(${SYSTEMCTL} status fstrim.timer --property=OnCalendar 2>/dev/null | ${AWK} -F'=' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
            ${ECHO} -e "   状态：${GREEN}已启用${NC} | 执行周期：${cycle}"
        fi
    else
        ${ECHO} -e "   状态：${RED}未启用${NC}"
    fi

    # 5 fstab挂载参数状态
    ${ECHO} -e "\n${BLUE}5 fstab挂载参数（仅兼容分区，添加noatime）${NC}"
    local temp_file="${HOME}/.disk-optimize-backups/compat_partitions.tmp"
    if [[ -f "${temp_file}" && -s "${temp_file}" ]]; then
        optimized_count=0
        total_count=0
        while IFS=':' read -r dev mount_point fs_type; do
            if [[ -z "${dev}" ]]; then
                continue
            fi
            dev_escaped="${dev//\//\\/}"
            total_count=$((total_count + 1))
            if ${GREP} -q "^${dev_escaped}.*noatime" /etc/fstab 2>/dev/null; then
                optimized_count=$((optimized_count + 1))
                if [[ " ${SSD_DEVICES[*]} " =~ $(basename "${dev}") && "${KERNEL_VER}" -ge 418 ]]; then
                    if ${GREP} -q "^${dev_escaped}.*discard=async" /etc/fstab 2>/dev/null; then
                        ${ECHO} -e "   ${dev}：${GREEN}已优化${NC} | 参数：noatime+discard=async（SSD）"
                    else
                        ${ECHO} -e "   ${dev}：${YELLOW}部分优化${NC} | 参数：noatime（缺少discard=async）"
                    fi
                else
                    ${ECHO} -e "   ${dev}：${GREEN}已优化${NC} | 参数：noatime（HDD）"
                fi
            else
                ${ECHO} -e "   ${dev}：${RED}未优化${NC} | 当前：无noatime | 最优：noatime"
            fi
        done < "${temp_file}"
        if [[ ${optimized_count} -eq ${total_count} && ${total_count} -gt 0 ]]; then
            ${ECHO} -e "   总体状态：${GREEN}全部已优化${NC}（${optimized_count}/${total_count}）"
        elif [[ ${total_count} -gt 0 ]]; then
            ${ECHO} -e "   总体状态：${YELLOW}部分已优化${NC}（${optimized_count}/${total_count}）"
        fi
    else
        ${ECHO} -e "   状态：${YELLOW}未检测${NC} | 原因：无兼容分区或未运行检测"
    fi

    # 2. IO调度器状态
    ${ECHO} -e "\n${BLUE}2. IO调度器${NC}"
    for dev in "${SSD_DEVICES[@]}"; do
        optimal="none"
        if [[ "${dev}" != "nvme"* ]]; then optimal="noop"; fi
        scheduler_path="/sys/block/${dev}/queue/scheduler"
        current=$(${CAT} "${scheduler_path}" 2>/dev/null | ${AWK} -F'[][]' '{print $2}' || ${ECHO} "未知")
        if [[ "${current}" == "${optimal}" ]]; then
            ${ECHO} -e "   SSD(${dev})：${GREEN}已优化${NC} | 当前：${current}（最优）"
        else
            ${ECHO} -e "   SSD(${dev})：${RED}未优化${NC} | 当前：${current} | 最优：${optimal}"
        fi
    done
    for dev in "${HDD_DEVICES[@]}"; do
        optimal="mq-deadline"
        scheduler_path="/sys/block/${dev}/queue/scheduler"
        current=$(${CAT} "${scheduler_path}" 2>/dev/null | ${AWK} -F'[][]' '{print $2}' || ${ECHO} "未知")
        if [[ "${current}" == "${optimal}" ]]; then
            ${ECHO} -e "   HDD(${dev})：${GREEN}已优化${NC} | 当前：${current}（最优）"
        else
            ${ECHO} -e "   HDD(${dev})：${RED}未优化${NC} | 当前：${current} | 最优：${optimal}"
        fi
    done

    # 3. 预读大小状态
    ${ECHO} -e "\n${BLUE}3. 预读大小${NC}"
    for dev in "${SSD_DEVICES[@]}"; do
        readahead_path="/sys/block/${dev}/queue/read_ahead_kb"
        current=$(${CAT} "${readahead_path}" 2>/dev/null || ${ECHO} "未知")
        if [[ "${current}" == "256" ]]; then
            ${ECHO} -e "   SSD(${dev})：${GREEN}已优化${NC} | 当前：${current}KB（最优）"
        else
            ${ECHO} -e "   SSD(${dev})：${RED}未优化${NC} | 当前：${current}KB | 最优：256KB"
        fi
    done
    for dev in "${HDD_DEVICES[@]}"; do
        readahead_path="/sys/block/${dev}/queue/read_ahead_kb"
        current=$(${CAT} "${readahead_path}" 2>/dev/null || ${ECHO} "未知")
        if [[ "${current}" == "1024" ]]; then
            ${ECHO} -e "   HDD(${dev})：${GREEN}已优化${NC} | 当前：${current}KB（最优）"
        else
            ${ECHO} -e "   HDD(${dev})：${RED}未优化${NC} | 当前：${current}KB | 最优：1024KB"
        fi
    done

    # 4. HDD APM状态
    ${ECHO} -e "\n${BLUE}4. HDD电源管理APM${NC}"
    if [[ ${#HDD_DEVICES[@]} -gt 0 && -x "${HDPARM}" ]]; then
        for dev in "${HDD_DEVICES[@]}"; do
            dev_path="/dev/${dev}"
            current=$(${HDPARM} -B "${dev_path}" 2>/dev/null | ${AWK} '
/APM_level/ {
    if ($0 ~ /not supported/) {
        print "不支持"
    } else {
        # 提取等号后面的值，去除空格
        for(i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/) {
                print $i
                exit
            }
        }
        print "未知"
    }
}' || ${ECHO} "未知")
            if [[ "${current}" == "128" ]]; then
                ${ECHO} -e "   HDD(${dev})：${GREEN}已优化${NC} | 当前：${current}（最优）"
            elif [[ "${current}" == "不支持" ]]; then
                ${ECHO} -e "   HDD(${dev})：${YELLOW}不支持APM${NC} | 硬件限制"
            else
                ${ECHO} -e "   HDD(${dev})：${RED}未优化${NC} | 当前：${current} | 最优：128"
            fi
        done
    else
        ${ECHO} -e "   状态：${YELLOW}未检测${NC} | 原因：无HDD或未安装hdparm"
    fi

    # 6. blk-mq状态
    ${ECHO} -e "\n${BLUE}6. blk-mq多核IO${NC}"
    if ${GREP} -q "blk-mq" /etc/default/grub 2>/dev/null; then
        ${ECHO} -e "   状态：${GREEN}已配置${NC} | 需重启生效"
    else
        ${ECHO} -e "   状态：${RED}未配置${NC}"
    fi

    # 7. 定时任务状态
    ${ECHO} -e "\n${BLUE}7. 定时检测任务${NC}"
    if ${CRONTAB} -l 2>/dev/null | ${GREP} -q "${CRON_SCRIPT}"; then
        ${ECHO} -e "   状态：${GREEN}已启用${NC} | 检测间隔：每${CHECK_INTERVAL}分钟 | 日志：${CRON_LOG}"
    else
        ${ECHO} -e "   状态：${RED}未启用${NC}"
    fi

    ${ECHO} -e "\n${PURPLE}============================================================"${NC}
    read -p "按回车返回菜单... " -n 1 -s
    ${ECHO} -e "\n"
}

# ===================== 菜单交互（保留历史输出） =====================
show_menu() {
    # 用分隔线替代clear，保留历史输出
    ${ECHO} -e "\n${BLUE}===================== 硬盘IO&寿命优化工具（保留历史输出版） =====================${NC}"
    ${ECHO} -e "核心原则：仅修改ext4/xfs/btrfs分区，FAT/NTFS分区完全保持原样"
    ${ECHO} -e "系统信息：${DISTRO} | 内核：$(${UNAME} -r) | 备份目录：${BACKUP_DIR}"
    ${ECHO} -e "SSD设备：${SSD_DEVICES[*]:-无} | HDD设备：${HDD_DEVICES[*]:-无}"
    ${ECHO} -e "=========================================================================="
    ${ECHO} -e "【一键操作】"
    ${ECHO} -e "1. 一键智能优化（默认临时生效，自动添加定时任务）"
    ${ECHO} -e "【单项优化】"
    ${ECHO} -e "2. 启用SSD定时TRIM（立即生效，永久自启）"
    ${ECHO} -e "3. 配置IO调度器（SSD=none/noop | HDD=mq-deadline）"
    ${ECHO} -e "4. 调整预读大小（SSD=256KB | HDD=1024KB）"
    ${ECHO} -e "5. 配置HDD电源管理APM（仅HDD，平衡性能和功耗）"
    ${ECHO} -e "6. 优化fstab挂载参数（仅兼容分区，添加noatime）"
    ${ECHO} -e "7. 启用blk-mq多核IO（需重启，适配多核CPU+NVMe）"
    ${ECHO} -e "【配置管理】"
    ${ECHO} -e "8. 手动备份配置文件"
    ${ECHO} -e "9. 回滚配置到最近备份"
    ${ECHO} -e "10. 移除定时检测任务"
    ${ECHO} -e "11. 查看当前优化状态"
    ${ECHO} -e "0. 退出脚本"
    ${ECHO} -e "=========================================================================="
    read -p "请输入操作编号（0-11）：" choice
}

# 一键智能优化
optimize_all() {
    ${ECHO} -e "\n${YELLOW}⚠️  一键优化将执行以下操作：${NC}"
    ${ECHO} -e "1. 优化fstab（仅兼容分区）"
    ${ECHO} -e "2. 配置IO调度器（临时生效）"
    ${ECHO} -e "3. 调整预读大小"
    ${ECHO} -e "4. 启用SSD TRIM（如有SSD）"
    ${ECHO} -e "5. 配置HDD APM（如有HDD）"
    ${ECHO} -e "6. 添加定时任务自动恢复"
    read -p "输入 y 确认执行（否则取消）：" confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        return 0
    fi

    TEMP_ONLY=1
    optimize_fstab
    optimize_scheduler
    optimize_readahead
    optimize_trim
    optimize_hdd_apm

    ${ECHO} -e "\n${GREEN}===================== 一键优化完成 =====================${NC}"
    ${ECHO} -e "✅ 所有兼容分区已优化，不兼容分区保持原样"
    ${ECHO} -e "✅ 临时优化项已生效，定时任务每${CHECK_INTERVAL}分钟检测恢复"
    ${ECHO} -e "⚠️  永久生效需执行单项优化选择「永久」并重启系统"
    read -p "按回车返回菜单... " -n 1 -s
    ${ECHO} -e "\n"
}

# ===================== 主流程 =====================
main() {
    # 检查是否为root
    if [[ $(${ID} -u) -ne 0 ]]; then
        ${ECHO} -e "${RED}错误：请以root权限运行脚本（sudo -i 或 su root）${NC}"
        exit 1
    fi

    # 初始化备份目录
    ${MKDIR} -p "${BACKUP_DIR}" 2>/dev/null || true

    # 免责声明（移除clear，保留历史）
    ${ECHO} -e "\n${RED}===================== 免责声明 =====================${NC}"
    ${ECHO} -e "1. 本脚本仅修改ext4/xfs/btrfs分区，FAT/NTFS分区完全保持原样；"
    ${ECHO} -e "2. 执行前自动备份配置，若出错会自动回滚；"
    ${ECHO} -e "3. 建议在测试环境验证后，再用于生产环境；"
    ${ECHO} -e "4. 作者不对脚本执行后的任何系统问题负责。"
    ${ECHO} -e "${RED}====================================================${NC}"
    read -p "请阅读以上声明，输入 y 确认继续（否则退出）：" confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        ${ECHO} -e "${YELLOW}用户取消操作，脚本退出${NC}"
        exit 0
    fi

    # 基础检测
    detect_disk_type
    detect_partitions

    # 菜单循环
    while true; do
        show_menu
        case "${choice}" in
            1) optimize_all ;;
            2) optimize_trim ;;
            3) optimize_scheduler ;;
            4) optimize_readahead ;;
            5) optimize_hdd_apm ;;
            6) optimize_fstab ;;
            7) optimize_blkmq ;;
            8) safe_backup "manual" ;;
            9) rollback_config ;;
            10) remove_cron_job ;;
            11) show_status ;;
            0) 
                ${ECHO} -e "${GREEN}\n脚本退出，感谢使用！${NC}"
                ${RM} -f "${TEMP_FILE}" 2>/dev/null || true
                exit 0
                ;;
            *) ${ECHO} -e "${RED}\n输入错误，请输入0-11的数字${NC}"; ${SLEEP} 2 ;;
        esac
    done
}

# 启动主流程
main