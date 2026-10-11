#!/bin/bash
#=======================================================================
# Acme-lsh 一键ACME证书申请脚本
# 版本：V2026.10.05（多域名证书管理 + 多域名到期前自动续期）
#
# 本次改动摘要（V2026.09.29 → V2026.10.05）：
#   1. 修复：菜单1/2把流程包在 ( ) 子shell 里执行，nginx_stop 注册的
#      trap 随子shell结束而失效，流程中任何 exit 都会让 nginx 永久停机。
#      现在流程在主shell运行，nginx 的停止/恢复由明确的函数控制。
#   2. 修复：旧版 `lsof -i :80 | awk '{print "kill -9",$2}' | sh` 会无差别
#      杀死80端口上的所有进程，包括 nginx 之外的业务服务。现在只停止
#      systemctl 管理的 nginx，其他进程仅列出并需用户确认后才终止。
#   3. 修复：旧版续期 crontab 写成 `0 0 * * * root bash ...`，在 root 的
#      crontab 里多出的 root 字段会被当成命令名。现改为标准5字段条目。
#   4. 修复：旧版自动续期（cron 直接跑 acme.sh）时没有任何人停止 nginx，
#      80端口被占用导致续期必然失败。现在把 pre-hook/reloadcmd 写入证书
#      自身的续期配置，acme.sh 自动续期时会自己停/启 nginx。
#   5. 修复：IP校验用 [[ ! $domainIP =~ $v4 ]]，纯IPv6机器上 $v4 为空会让
#      正则匹配一切导致校验失效；现改为逐条精确比较。
#   6. 修复：ca.log 被每个域名覆盖、/tmp 固定临时文件、重复安装acme.sh、
#      卸载前先重装、依赖判断依赖当前目录标记文件等问题。
#   7. 新增：菜单4「批量域名自动续期配置」，一次输入多个域名。
#=======================================================================
export LANG=en_US.UTF-8
red='\033[0;31m'
bblue='\033[0;34m'
plain='\033[0m'
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" "$2";}

ACME_BIN=""          # 由 acme_locate 在多个候选路径中自动定位
ACME_HOME=""
CERT_DIR="/root/lshca"
CRON_MARK="# acme-lsh 自动续期任务（由脚本管理，请勿手工删除）"
LOGFILE=""
RENEW_DAYS_DEFAULT=30

if [[ $EUID -ne 0 ]]; then
red "请以 root 模式运行脚本" && exit 1
fi

#[[ -e /etc/hosts ]] && grep -qE '^ *172.65.251.78 gitlab.com' /etc/hosts || echo -e '\n172.65.251.78 gitlab.com' >> /etc/hosts
if [[ -f /etc/redhat-release ]]; then
release="Centos"
elif cat /etc/issue 2>/dev/null | grep -q -E -i "alpine"; then
release="alpine"
elif cat /etc/issue 2>/dev/null | grep -q -E -i "debian"; then
release="Debian"
elif cat /etc/issue 2>/dev/null | grep -q -E -i "ubuntu"; then
release="Ubuntu"
elif cat /etc/issue 2>/dev/null | grep -q -E -i "centos|red hat|redhat"; then
release="Centos"
elif cat /proc/version 2>/dev/null | grep -q -E -i "debian"; then
release="Debian"
elif cat /proc/version 2>/dev/null | grep -q -E -i "ubuntu"; then
release="Ubuntu"
elif cat /proc/version 2>/dev/null | grep -q -E -i "centos|red hat|redhat"; then
release="Centos"
else
red "不支持当前的系统，请选择使用Ubuntu,Debian,Centos系统" && exit 1
fi
vsid=$(grep -i version_id /etc/os-release 2>/dev/null | cut -d \" -f2 | cut -d . -f1)
op=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -i pretty_name | cut -d \" -f2)
if [[ $(echo "$op" | grep -i -E "arch") ]]; then
red "脚本不支持当前的 $op 系统，请选择使用Ubuntu,Debian,Centos系统。" && exit 1
fi

v4v6(){
v4=$(curl -s4m5 icanhazip.com -k)
v6=$(curl -s6m5 icanhazip.com -k)
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

pkg_install(){
# 统一依赖安装入口，按发行版把"命令名"映射成实际包名
local cmd="$1" pkg="$1"
if have_cmd apt-get; then
case "$cmd" in
dig) pkg="dnsutils" ;;
ss) pkg="iproute2" ;;
crontab) pkg="cron" ;;
esac
DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
return
fi
if have_cmd dnf || have_cmd yum; then
case "$cmd" in
dig) pkg="bind-utils" ;;
ss) pkg="iproute" ;;
crontab) pkg="cronie" ;;
esac
if have_cmd dnf; then dnf install -y "$pkg" >/dev/null 2>&1; else yum install -y "$pkg" >/dev/null 2>&1; fi
return
fi
have_cmd apk && apk add "$cmd" >/dev/null 2>&1
}

first_install(){
# 旧版用当前目录下的 acyg_update 文件判断是否首次安装，换个目录运行就会
# 重复执行一遍全量依赖安装。现在按依赖命令是否真的存在来判断。
need=()
have_cmd curl || need+=(curl)
have_cmd openssl || need+=(openssl)
have_cmd lsof || need+=(lsof)
have_cmd socat || need+=(socat)
have_cmd dig || need+=(dig)
have_cmd tar || need+=(tar)
have_cmd wget || need+=(wget)
have_cmd ss || need+=(ss)
have_cmd crontab || need+=(crontab)
if [[ ${#need[@]} -eq 0 ]]; then
return 0
fi
green "首次安装Acme-lsh脚本必要的依赖……"
if [[ "$release" == "alpine" ]]; then
apk add wget curl tar jq tzdata openssl expect git socat iproute2 virt-what >/dev/null 2>&1
else
if have_cmd apt-get; then
apt-get update -y >/dev/null 2>&1
elif have_cmd dnf; then
: # dnf 的元数据在 install 时自动刷新
elif have_cmd yum; then
yum install -y epel-release >/dev/null 2>&1
fi
if [[ $release == Centos && ${vsid} =~ ^8 ]]; then
# 只在确有源文件时备份，避免重复运行时 mkdir/mv 报错
if ls /etc/yum.repos.d/*.repo >/dev/null 2>&1; then
mkdir -p /etc/yum.repos.d/backup
mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null
curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-8.repo >/dev/null 2>&1
sed -i -e "s|mirrors.cloud.aliyuncs.com|mirrors.aliyun.com|g " /etc/yum.repos.d/CentOS-* 2>/dev/null
sed -i -e "s|releasever|releasever-stream|g" /etc/yum.repos.d/CentOS-* 2>/dev/null
yum clean all >/dev/null 2>&1 && yum makecache >/dev/null 2>&1
fi
fi
fi
local c
for c in "${need[@]}"; do
pkg_install "$c"
done
for c in "${need[@]}"; do
have_cmd "$c" || red "依赖 $c 安装失败，可能影响部分功能"
done
green "依赖检查完成"
}

v4v6
if [[ -z "$(curl -s4m5 icanhazip.com -k)" ]]; then
yellow "检测到VPS为纯IPV6，添加dns64"
echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2c::1\nnameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf
sleep 2
fi

#=======================================================================
# acme.sh 定位
# 不再写死 ~/.acme.sh/acme.sh：这不是判断 acme.sh 是否安装的依据。
# 官方安装脚本写入 $HOME/.acme.sh，但 LE_WORKING_DIR 环境变量、软链接安装、
# 包管理器安装等都会落在别的位置，写死路径会把已安装的 acme.sh 误判为"未安装"。
# 这里按顺序探测，并用 -v 是否真的返回版本号来确认可执行。
#=======================================================================
ACME_DIAG=""
acme_probe(){
# 详细探测 acme.sh。判定顺序（从可靠到宽松）：
#   1. -v 退出码为 0            —— 最可靠的信号
#   2. -v 输出里出现 vX.Y 版本号 —— 兼容退出码被外层包装吞掉的情况
#   3. 文件是 acme.sh 脚本内容且 --version 能跑通
# 真实环境里 -v 会返回多行（上游 version() 先打印项目地址再打印版本号），
# 所以不能要求输出"长得像一个版本号"，那样会把正常的 acme.sh 判成未安装。
# 探测结论写入 $ACME_DIAG，菜单会直接显示，不必靠猜。
ACME_DIAG=""
local c v rc ver_re
ver_re='[vV][0-9]+\.[0-9]+'
for c in \
"$ACME_BIN" \
"$HOME/.acme.sh/acme.sh" \
"/root/.acme.sh/acme.sh" \
"/usr/local/bin/acme.sh" \
"/usr/bin/acme.sh"; do
[[ -n "$c" ]] || continue
if [[ ! -e "$c" ]]; then
ACME_DIAG="$ACME_DIAG  · $c ：不存在"$'\n'
continue
fi
if [[ ! -x "$c" ]]; then
ACME_DIAG="$ACME_DIAG  · $c ：存在但没有可执行权限"$'\n'
continue
fi
if [[ ! -r "$c" ]]; then
ACME_DIAG="$ACME_DIAG  · $c ：存在但没有读取权限"$'\n'
continue
fi
v=$("$c" -v 2>&1)
rc=$?
if [[ $rc -eq 0 || "$v" =~ $ver_re ]]; then
ACME_BIN="$c"
ACME_HOME="$(dirname "$c")"
LOGFILE="$ACME_HOME/acme-lsh-renew.log"
ACME_DIAG="$ACME_DIAG  · $c ：可用（$(printf '%s' "$v" | tr '\n' ' ' | cut -c1-60)）"$'\n'
return 0
fi
ACME_DIAG="$ACME_DIAG  · $c ：-v 异常（退出码=$rc，输出：$(printf '%s' "$v" | tr '\n' ' ' | cut -c1-60)）"$'\n'
done
ACME_BIN="$HOME/.acme.sh/acme.sh"
ACME_HOME="$HOME/.acme.sh"
LOGFILE="$ACME_HOME/acme-lsh-renew.log"
return 1
}

acme_locate(){ acme_probe >/dev/null 2>&1; }

acme_installed(){ acme_probe >/dev/null 2>&1; }

#=======================================================================
# nginx 生命周期管理
# 旧版把 nginx_stop 放在子shell里注册 trap，子shell一结束 trap 就失效，
# 加上各函数里散落的裸 exit，很容易让 nginx 一直停着。这里改成：
#   · stop 前记录 nginx 原本是否在运行，只恢复自己停掉的服务
#   · 致命分支一律 return，由调用方负责恢复
#   · 菜单层做兜底，任何路径返回后都检查并恢复 nginx
#=======================================================================
nginx_was_running=0

nginx_stop(){
if systemctl is-active --quiet nginx 2>/dev/null; then
yellow "检测到Nginx正在运行，现停止Nginx服务"
systemctl stop nginx >/dev/null 2>&1
green "Nginx已停止"
nginx_was_running=1
else
nginx_was_running=0
fi
}

nginx_start(){
if [[ $nginx_was_running -eq 1 ]]; then
yellow "正在重新启动Nginx服务……"
systemctl start nginx >/dev/null 2>&1
if systemctl is-active --quiet nginx 2>/dev/null; then
green "Nginx已成功重新启动"
else
red "Nginx重启失败，请手动执行 systemctl start nginx 检查！"
fi
fi
nginx_was_running=0
}

port80_pids(){
# 只取监听80端口的进程PID。列顺序固定为 进程名=PID，用 sed 精确提取，
# 不再像旧版那样拿整行去拼 kill 命令
if have_cmd ss; then
ss -lptnH "sport = :80" 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u
elif have_cmd lsof; then
lsof -ti :80 2>/dev/null | sort -u
fi
}

port80_desc(){
if have_cmd ss; then
ss -lptnH "sport = :80" 2>/dev/null | sed -n 's/.*users:((\"\([^\"]*\)\",pid=\([0-9]*\).*/\1(pid=\2)/p' | sort -u | tr '\n' ' '
elif have_cmd lsof; then
lsof -i :80 2>/dev/null | awk 'NR>1{print $1"(pid="$2")"}' | sort -u | tr '\n' ' '
fi
}

wait_port80_free(){
local i
for i in $(seq 1 15); do
[[ -z "$(port80_pids)" ]] && return 0
sleep 1
done
return 1
}

ensure_port80_free(){
# 释放80端口：只停自己管得住的 nginx；剩下的进程先展示再让用户决定。
# 返回0表示80端口已可用，返回1表示用户取消或无法释放。
nginx_stop
if [[ -z "$(port80_pids)" ]]; then
return 0
fi
yellow "80端口仍被以下进程占用："
yellow "  $(port80_desc)"
yellow "1：停止以上进程后再申请（这些进程会被终止）"
yellow "2：不停止，返回菜单"
readp "请选择：" p80sel
if [[ "$p80sel" != "1" ]]; then
red "已取消，未做任何改动"
return 1
fi
local pids p
pids=$(port80_pids)
if [[ -n "$pids" ]]; then
for p in $pids; do
kill -15 "$p" >/dev/null 2>&1
done
sleep 2
for p in $pids; do
kill -0 "$p" >/dev/null 2>&1 && kill -9 "$p" >/dev/null 2>&1
done
fi
if wait_port80_free; then
green "80端口已释放完毕"
return 0
fi
red "80端口仍被占用，无法使用独立80端口模式"
return 1
}

#=======================================================================
# acme.sh 通用助手
# （acme_installed / acme_locate 定义在上面，便于其他函数调用）
#=======================================================================

acme_list_raw(){
# --listraw 是 --list 的修饰参数，不能单独当命令用。
# 单独写 `acme.sh --listraw` 时 acme.sh 会打印整段帮助文本，
# 若再用 tail 截掉首行，帮助文本就会被当成证书列表（菜单里会刷出一大段参数说明）。
# 输出的列顺序：域名|KeyLength|SAN|Profile|CA|创建时间|续期时间
local out
out=$("$ACME_BIN" --list --listraw 2>/dev/null) || return 0
out=$(printf '%s\n' "$out" | tail -n +2)
if [[ -n "$out" ]]; then
printf '%s\n' "$out"
return 0
fi
# 兼容不支持 --listraw 的旧版 acme.sh：退回按列解析普通 --list 输出
"$ACME_BIN" --list 2>/dev/null | tail -n +2 | awk 'NF>0 {print $1"|"$2}'
}

acme_domain_list(){
# 加一道保险：万一 acme.sh 输出的是帮助/报错文本，这里按"域名形状"过滤掉。
# 规则：不以 - 开头，至少一个点，标签由 字母/数字/下划线/点/连字符 组成
# （* 会被去掉，所以 *.example.com 变成 example.com 仍能通过）
acme_list_raw | awk -F'|' '
$1 !~ /^-/ && $1 ~ /\./ && $1 ~ /^[A-Za-z0-9_][A-Za-z0-9._-]*$/ && length($1) <= 253 {print $1}
' | sort -u
}

acme_domain_exists(){
[[ -z "$1" ]] && return 1
acme_domain_list | grep -qxF "$1"
}

acme_domain_is_ecc(){
# 由 KeyLength 判断该域名走 --ecc 还是 RSA
local kl
kl=$(acme_list_raw | awk -F'|' -v dom="$1" '$1==dom {print $2; exit}' | tr -d '"' | tr 'A-Z' 'a-z')
case "$kl" in
*ec*|*secp*|*prime256*|*ed25519*) return 0 ;;
esac
[[ -d "$ACME_HOME/$1_ecc" ]] && return 0
return 1
}

acme_ecc_arg(){
acme_domain_is_ecc "$1" && printf '%s' "--ecc"
}

cert_conf_path(){
if [[ -f "$ACME_HOME/$1_ecc/$1.conf" ]]; then
printf '%s' "$ACME_HOME/$1_ecc/$1.conf"
elif [[ -f "$ACME_HOME/$1/$1.conf" ]]; then
printf '%s' "$ACME_HOME/$1/$1.conf"
fi
}

read_conf_var(){
# 只提取简单赋值行，不 source 整个配置文件
local f="$1" k="$2"
[[ -f "$f" ]] || return 0
sed -n "s/^${k}=//p" "$f" | tail -n 1 | sed -e 's/^"//' -e 's/"$//'
}

cert_file_of(){
local f cp
f=$(read_conf_var "$(cert_conf_path "$1")" Le_RealFullChainPath)
if [[ -n "$f" ]]; then printf '%s' "$f"; return 0; fi
[[ -f "$CERT_DIR/$1.crt" ]] && printf '%s' "$CERT_DIR/$1.crt" && return 0
cp=$(read_conf_var "$(cert_conf_path "$1")" CERT_FULLCHAIN_PATH)
[[ -n "$cp" ]] && printf '%s' "$cp"
}

cert_days_left(){
# 输出证书剩余有效天数；取不到输出空
local crt na ts
crt=$(cert_file_of "$1")
[[ -f "$crt" ]] || return 0
na=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)
[[ -z "$na" ]] && return 0
ts=$(date -d "$na" +%s 2>/dev/null)
[[ -z "$ts" ]] && return 0
echo $(( (ts - $(date +%s)) / 86400 ))
}

cert_webroot_of(){
# 只输出 ASCII 标识，避免 case 匹配依赖中文编码（脚本传输出错时不至于静默失效）
local wr
wr=$(read_conf_var "$(cert_conf_path "$1")" Le_Webroot)
case "$wr" in
"") printf '%s' "unknown" ;;
no) printf '%s' "standalone" ;;
*dns_*) printf '%s' "dns" ;;
*) printf '%s' "webroot" ;;
esac
}

webroot_label(){
case "$1" in
dns) printf '%s' "DNS API" ;;
standalone) printf '%s' "80端口" ;;
webroot) printf '%s' "webroot" ;;
*) printf '%s' "未知" ;;
esac
}

cert_san_count(){
local alt
alt=$(read_conf_var "$(cert_conf_path "$1")" Le_Alt)
if [[ -z "$alt" ]]; then printf '%s' "0"; else printf '%s' "$(echo "$alt" | tr ',' '\n' | grep -c .)"; fi
}

#=======================================================================
# nginx 续期钩子
# acme.sh 只在"真正需要续期"时执行 pre-hook / post-hook / reloadcmd，钩子内容随证书
# 一起保存在 $ACME_HOME/<域名>[_ecc]/<域名>.conf 里（base64 编码），所以自动续期时
# acme.sh 会自己停/启 nginx，不再依赖外部脚本在正确的时机介入。
#
# 三个钩子的分工（顺序：pre-hook → 验证 → post-hook → 装证书 → reloadcmd）：
#   pre-hook  续期开始前停掉 nginx，并留下标记文件
#   post-hook 只要本次跑过 pre-hook，就无条件把 nginx 拉回来 ——
#             这样即使签发失败，nginx 也不会一直停在停止状态
#   reloadcmd 证书安装完成后再次确认 nginx 已运行（幂等）
# DNS API 模式的证书不占80端口，钩子在那里是空操作，可安全保留。
#=======================================================================
renew_hook_setup(){
mkdir -p "$ACME_HOME"
cat > "$ACME_HOME/acme-lsh-renew-hook.sh" <<'HOOKEOF'
#!/bin/bash
# 由 Acme-lsh 脚本生成：acme.sh 续期前停止 nginx，腾出80端口
MARK="/tmp/acme-lsh-nginx-stopped"
if systemctl is-active --quiet nginx 2>/dev/null; then
systemctl stop nginx >/dev/null 2>&1
touch "$MARK"
fi
exit 0
HOOKEOF
cat > "$ACME_HOME/acme-lsh-post-hook.sh" <<'HOOKEOF'
#!/bin/bash
# 由 Acme-lsh 脚本生成：无论续期成功还是失败，都把 nginx 拉回来
MARK="/tmp/acme-lsh-nginx-stopped"
if [[ -f "$MARK" ]]; then
systemctl start nginx >/dev/null 2>&1
rm -f "$MARK"
fi
exit 0
HOOKEOF
cat > "$ACME_HOME/acme-lsh-reload-hook.sh" <<'HOOKEOF'
#!/bin/bash
# 由 Acme-lsh 脚本生成：证书安装完成后确认 nginx 已运行（幂等，可重复执行）
MARK="/tmp/acme-lsh-nginx-stopped"
if [[ -f "$MARK" ]]; then
systemctl start nginx >/dev/null 2>&1
rm -f "$MARK"
fi
if systemctl is-active --quiet nginx 2>/dev/null; then
echo "nginx 已恢复运行"
else
echo "nginx 未运行，请手动检查：systemctl status nginx"
fi
exit 0
HOOKEOF
chmod +x "$ACME_HOME/acme-lsh-renew-hook.sh" "$ACME_HOME/acme-lsh-post-hook.sh" "$ACME_HOME/acme-lsh-reload-hook.sh" 2>/dev/null
}

LE_RENEW_HOOK="/bin/bash $ACME_HOME/acme-lsh-renew-hook.sh"
LE_POST_HOOK="/bin/bash $ACME_HOME/acme-lsh-post-hook.sh"
LE_RELOAD_HOOK="/bin/bash $ACME_HOME/acme-lsh-reload-hook.sh"

apply_renew_hooks(){
# 把钩子写进证书的续期配置。
# 注意：acme.sh 的 --install-cert 只接受 --reloadcmd，并不解析 --pre-hook/--post-hook
# （上游 installcert() 的第5个参数才是 reloadcmd），所以这里先用 install-cert 落盘
# reloadcmd，再按 acme.sh 的格式补写 pre/post hook。
# acme.sh 对 base64 配置的格式要求是 __ACME_BASE64__START_<base64>__ACME_BASE64__END_，
# 直接写裸 base64 会导致读取时解码失败（这一点踩过一次）。
local d="$1" eccarg cp ok=0 b64
eccarg=$(acme_ecc_arg "$d")
renew_hook_setup
if "$ACME_BIN" --install-cert -d "$d" $eccarg \
--key-file "$CERT_DIR/$d.key" \
--fullchain-file "$CERT_DIR/$d.crt" \
--reloadcmd "$LE_RELOAD_HOOK" >/dev/null 2>&1; then
ok=1
fi
cp=$(cert_conf_path "$d")
if [[ -f "$cp" ]]; then
b64="__ACME_BASE64__START_$(printf '%s' "$LE_RENEW_HOOK" | openssl base64 -A)__ACME_BASE64__END_"
set_conf(){
# 已存在则原地替换（等价于 acme.sh 的 _setopt），不存在则追加
if grep -q "^$1=" "$cp"; then
sed -i "s|^$1=.*|$1='$2'|" "$cp"
else
printf "%s='%s'\n" "$1" "$2" >> "$cp"
fi
}
set_conf Le_PreHook "$b64"
b64="__ACME_BASE64__START_$(printf '%s' "$LE_POST_HOOK" | openssl base64 -A)__ACME_BASE64__END_"
set_conf Le_PostHook "$b64"
b64="__ACME_BASE64__START_$(printf '%s' "$LE_RELOAD_HOOK" | openssl base64 -A)__ACME_BASE64__END_"
set_conf Le_ReloadCmd "$b64"
if grep -q "^Le_PreHook=" "$cp" && grep -q "^Le_PostHook=" "$cp" && grep -q "^Le_ReloadCmd=" "$cp"; then
ok=1
fi
fi
[[ $ok -eq 1 ]]
}

#=======================================================================
# acme.sh 安装
# 旧版串了两条安装路径（github tarball + get.acme.sh），虽然是重复劳动，
# 但确实提供了容错。这里保留"两种下载源依次尝试"的思路，区别是：
#   · 每一步都有明确输出，失败时打印真正的原因，而不是静默重试后只报一句"失败"
#   · 优先用 codeload.github.com（国内可达性通常好于 raw.githubusercontent.com）
#=======================================================================
acme_download_install(){
# 用法：acme_download_install <邮箱>
local email="$1" tmp url rc=1
tmp=$(mktemp -d 2>/dev/null) || return 1
for url in \
"https://codeload.github.com/acmesh-official/acme.sh/tar.gz/refs/heads/master" \
"https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz"; do
yellow "下载源：$url"
rm -rf "$tmp"/acme.sh-* "$tmp"/master.tar.gz 2>/dev/null
if ! curl -fL --connect-timeout 15 -o "$tmp/master.tar.gz" "$url" 2>"$tmp/err"; then
red "  下载失败：$(tail -n 1 "$tmp/err" 2>/dev/null)"
continue
fi
if ! tar -xzf "$tmp/master.tar.gz" -C "$tmp" 2>"$tmp/err"; then
red "  解压失败：$(tail -n 1 "$tmp/err" 2>/dev/null)"
continue
fi
local dir
dir=$(find "$tmp" -maxdepth 1 -type d -name 'acme.sh-*' | head -n 1)
if [[ -z "$dir" ]]; then
red "  解压结果异常，未找到 acme.sh 源码目录"
continue
fi
if bash "$dir/acme.sh" --install --home "$HOME/.acme.sh" --accountemail "$email" \
--auto-upgrade >"$tmp/install.log" 2>&1; then
green "  安装命令执行成功"
rc=0
break
fi
red "  安装命令失败，最后几行输出："
tail -n 8 "$tmp/install.log" 2>/dev/null | sed 's/^/    /'
done
rm -rf "$tmp"
return $rc
}

acme_online_install(){
# 官方一键安装脚本，作为兜底。注意用文件保存输出而不是管道接 head，
# 否则管道会掩盖安装脚本真正的退出码。
local email="$1" log rc
log=$(mktemp) || return 1
if curl -fL --connect-timeout 15 https://get.acme.sh -o "$log.script" 2>/dev/null; then
sh "$log.script" --install-online --home "$HOME/.acme.sh" --accountemail "$email" --auto-upgrade >"$log" 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
tail -n 5 "$log" | sed 's/^/    /'
rm -f "$log" "$log.script"
return 0
fi
red "  官方安装脚本退出码 $rc，最后几行输出："
tail -n 8 "$log" 2>/dev/null | sed 's/^/    /'
else
red "  无法下载 https://get.acme.sh"
fi
rm -f "$log" "$log.script"
return 1
}

acme3(){
if acme_installed; then
green "检测到acme.sh证书申请程序已安装（$ACME_BIN），跳过重复安装"
return 0
fi
readp "请输入注册所需的邮箱（回车跳过则自动生成虚拟gmail邮箱）：" Aemail
if [[ -z "$Aemail" ]]; then
auto=$(date +%s%N | md5sum | cut -c 1-6)
Aemail="${auto}@gmail.com"
fi
yellow "当前注册的邮箱名称：$Aemail"
green "开始安装acme.sh申请证书脚本"
# 若安装位置已经有一个"不能正常运行"的 acme.sh（例如上次下载被中断留下的残缺文件），
# 官方安装脚本会直接拿旧文件报"已经安装"，重新安装永远修不好，所以先挪走再装。
local stale="$HOME/.acme.sh/acme.sh"
if [[ -e "$stale" ]]; then
yellow "检测到 $stale 已存在但无法正常运行，先备份为 acme.sh.broken 再重新安装"
mv -f "$stale" "$stale.broken" >/dev/null 2>&1
fi
local install_ok=0
if acme_download_install "$Aemail"; then
install_ok=1
else
yellow "第一种方式未成功，尝试官方一键安装脚本兜底……"
if acme_online_install "$Aemail"; then
install_ok=1
fi
fi
if acme_installed; then
green "安装acme.sh证书申请程序成功（$ACME_BIN）"
"$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1
return 0
fi
red "安装acme.sh证书申请程序失败"
yellow "排查建议："
yellow "1、确认服务器能访问 github：curl -I https://codeload.github.com"
yellow "2、确认 $HOME 可写、且 $HOME/.acme.sh 不存在同名只读文件"
yellow "3、查看 crontab/依赖是否正常：command -v crontab"
yellow "4、重试一次，上面的输出里会直接给出失败原因"
return 1
}

acme_issue(){
# 统一签发/续期入口：带上 pre/post hook 与 reloadcmd，让 acme.sh 把
# "续期时停 nginx、装完证书（或失败后）再拉起 nginx" 写进证书自己的续期配置。
# 这是 acme.sh 官方推荐做法：钩子只在真正需要换证时执行，之后自动续期无需人工介入。
local dom="$1" webroot="$2" extra="$3" ca="$4"
renew_hook_setup
if [[ -n "$ca" ]]; then
"$ACME_BIN" --issue $webroot -d "$dom" -k ec-256 $extra $ca \
--pre-hook "$LE_RENEW_HOOK" \
--post-hook "$LE_POST_HOOK" \
--reloadcmd "$LE_RELOAD_HOOK"
else
"$ACME_BIN" --issue $webroot -d "$dom" -k ec-256 $extra \
--pre-hook "$LE_RENEW_HOOK" \
--post-hook "$LE_POST_HOOK" \
--reloadcmd "$LE_RELOAD_HOOK"
fi
}

installCA(){
# 按域名自身的 key 类型决定是否带 --ecc，兼容 ECC 与 RSA 记录并存
local eccarg
ym="${1:-$ym}"
eccarg=$(acme_ecc_arg "$ym")
mkdir -p "$CERT_DIR"
"$ACME_BIN" --install-cert -d "$ym" $eccarg \
--key-file "$CERT_DIR/$ym.key" \
--fullchain-file "$CERT_DIR/$ym.crt" \
--reloadcmd "$LE_RELOAD_HOOK"
}

checktls(){
if [[ -f "$CERT_DIR/$ym.crt" && -f "$CERT_DIR/$ym.key" ]] && [[ -s "$CERT_DIR/$ym.crt" && -s "$CERT_DIR/$ym.key" ]]; then
cronac
mkdir -p "$CERT_DIR"
# 旧版这里直接覆盖 ca.log，多域名场景下记录没有意义，改为追加
echo "$(date '+%F %T') $ym 申请/更新成功" >> "$CERT_DIR/ca.log"
green "域名证书申请成功！证书已保存到 /root/lshca/ 目录（已有旧证书已自动覆盖更新）"
yellow "公钥文件crt路径如下，可直接复制"
green "/root/lshca/$ym.crt"
yellow "密钥文件key路径如下，可直接复制"
green "/root/lshca/$ym.key"
nginx_start
[[ -f '/etc/hysteria/config.json' ]] && blue "检测到Hysteria-1代理协议，如果你安装了Hysteria脚本，请在Hysteria脚本执行申请/变更证书，此证书将自动应用"
[[ -f '/etc/caddy/Caddyfile' ]] && blue "检测到Naiveproxy代理协议，如果你安装了Naiveproxy脚本，请在Naiveproxy脚本执行申请/变更证书，此证书将自动应用"
[[ -f '/etc/tuic/tuic.json' ]] && blue "检测到Tuic代理协议，如果你安装了Tuic脚本，请在Tuic脚本执行申请/变更证书，此证书将自动应用"
[[ -f '/usr/bin/x-ui' ]] && blue "检测到x-ui（xray代理协议），如果你安装了x-ui脚本，开启tls选项，此证书将自动应用"
[[ -f '/etc/s-box/sb.json' ]] && blue "检测到Sing-box内核代理，如果你安装了Sing-box脚本，请在Sing-box脚本执行申请/变更证书，此证书将自动应用"
return 0
fi
nginx_start
# 申请失败仅清理本次域名的残留记录，保留 acme.sh 程序与其他域名证书
"$ACME_BIN" --remove -d "$ym" $(acme_ecc_arg "$ym") >/dev/null 2>&1
rm -f "$CERT_DIR/$ym.crt" "$CERT_DIR/$ym.key"
red "遗憾，域名证书申请失败，建议如下："
yellow "1、如果解析到的IP是104.2开头的或者172开头的IP，请确保CF中的CDN黄云已关闭，解析的IP必须是VPS的本地IP"
echo
yellow "2、更换下二级域名自定义名称再尝试重新申请（重要）"
green "例：原二级域名 x.lsh.eu.org 或 x.lsh.cf ，在cloudflare中重命名其中的x名称"
echo
yellow "3、因为同个本地IP连续多次申请证书有时间限制，等一段时间再重新申请"
echo
yellow "4、80端口模式要求申请瞬间80端口能被acme.sh占用，Nginx会被临时停止并在结束后自动恢复"
return 1
}

checkip(){
v4v6
if [[ -z "$v4" ]]; then
vpsip="$v6"
elif [[ -n "$v4" && -n "$v6" ]]; then
vpsip="$v6 或者 $v4"
else
vpsip="$v4"
fi
local v4list v6list match=0
v4list=$(dig @8.8.8.8 +time=2 +short A "$ym" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
v6list=$(dig @2001:4860:4860::8888 +time=2 +short AAAA "$ym" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$')
domainIP=$(printf '%s\n%s\n' "$v4list" "$v6list" | grep -v '^$' | head -n 1)
if [[ -z "$domainIP" ]]; then
red "未解析出IP，请检查域名是否输入有误"
yellow "是否尝试手动输入强行匹配？"
yellow "1：是！输入域名解析的IP"
yellow "2：否！返回菜单"
readp "请选择：" menu
if [ "$menu" = "1" ]; then
green "VPS本地的IP：$vpsip"
readp "请输入域名解析的IP，与VPS本地IP($vpsip)保持一致：" domainIP
else
return 1
fi
elif [[ "$domainIP" == *:* ]]; then
green "当前域名解析到的IPV6地址：$domainIP"
else
green "当前域名解析到的IPV4地址：$domainIP"
fi
# 旧版用 [[ ! $domainIP =~ $v4 ]] 判断，纯IPv6机器上 $v4 为空会让正则匹配一切。
# 这里对每条解析记录做精确比较，任一命中即视为匹配。
if [[ -n "$v4" ]] && echo "$v4list" | grep -qxF "$v4"; then match=1; fi
if [[ -n "$v6" ]] && echo "$v6list" | grep -qxF "$v6"; then match=1; fi
if [[ -n "$v6" && "$domainIP" == "$v6" ]]; then match=1; fi
if [[ $match -eq 1 ]]; then
green "IP匹配正确，申请证书开始…………"
return 0
fi
yellow "当前VPS本地的IP：$vpsip"
red "当前域名解析的IP与当前VPS本地的IP不匹配！！！"
green "建议如下："
if [[ "$v6" == "2a09"* || "$v4" == "104.28"* ]]; then
yellow "WARP未能自动关闭，请手动关闭！或者使用支持自动关闭与开启的甬哥WARP脚本"
else
yellow "1、请确保CDN小黄云关闭状态(仅限DNS)，其他域名解析网站设置同理"
yellow "2、请检查域名解析网站设置的IP是否正确"
fi
readp "是否仍然继续申请？1:继续 2:返回菜单：" ipgo
[[ "$ipgo" == "1" ]] && return 0
return 1
}

checkacmeca(){
if [[ "$ym" == *ip6.arpa* ]]; then
red "目前不支持ip6.arpa域名申请证书"
return 1
fi
# 精确匹配主域名；旧版用 grep（正则），*.example.com 之类的输入会被当成模式误判
if acme_domain_exists "$ym"; then
red "经检测，输入的域名已有证书申请记录，不用重复申请"
red "证书申请记录如下："
"$ACME_BIN" --list
yellow "如果一定要重新申请，请先执行菜单5删除证书"
return 1
fi
return 0
}

checkns(){
basedomain=$(echo "$ym" | sed 's/^\*\.//')
nsrecord=$(dig +time=3 +tries=2 NS "$basedomain" +short 2>/dev/null)
if [[ -z "$nsrecord" ]]; then
yellow "提示：暂未查询到 $basedomain 的NS记录，无法预先确认DNS托管状态，将直接尝试申请"
return 0
fi
case "$1" in
cf ) matchstr="cloudflare" ;;
dp ) matchstr="dnspod\|qq\.com" ;;
ali ) matchstr="hichina\|alidns\|aliyun" ;;
esac
if ! echo "$nsrecord" | grep -qi "$matchstr"; then
yellow "提示：查询到 $basedomain 当前NS记录为：$(echo $nsrecord | tr '\n' ' ')"
yellow "与你选择的服务商特征不完全匹配。DNS-01验证只认域名实际的NS指向，与域名后缀/注册商无关"
yellow "如果域名尚未把NS改到该服务商，申请会验证失败；如果已经改了只是这里没识别出来，可以选择继续"
readp "是否继续申请？1:继续 2:取消返回：" nscontinue
[[ "$nscontinue" != "1" ]] && return 1
fi
return 0
}

#=======================================================================
# 证书申请：独立80端口模式
#=======================================================================
ACMEstandaloneDNS(){
v4v6
readp "请输入解析完成的域名（输入0返回上一级）:" ym
[[ -z "$ym" || "$ym" == "0" ]] && return
green "已输入的域名:$ym" && sleep 1
checkacmeca || return
ensure_port80_free || return
if ! checkip; then
nginx_start
return
fi
if [[ -n "$v6" && "$domainIP" == "$v6" ]]; then
acme_issue "$ym" "--standalone --listen-v6" "" "--server letsencrypt --insecure"
else
acme_issue "$ym" "--standalone" "" "--server letsencrypt --insecure"
fi
installCA
checktls
}

#=======================================================================
# 证书申请：DNS API模式
#=======================================================================
ACMEDNS(){
readp "请输入解析完成的域名（输入0返回上一级）:" ym
[[ -z "$ym" || "$ym" == "0" ]] && return
green "已输入的域名:$ym" && sleep 1
checkacmeca || return
# DNS API模式走DNS-01验证，不需要占用80端口，因此不调用 nginx_stop
if [[ -n $(echo "$ym" | grep '\*') ]]; then
green "经检测，当前为泛域名证书申请，" && sleep 2
else
green "经检测，当前为单域名证书申请，" && sleep 2
fi
echo
ab="请选择托管域名解析服务商：\n1.Cloudflare\n2.腾讯云DNSPod\n3.阿里云Aliyun\n0.返回上一级\n 请选择："
readp "$ab" cd
case "$cd" in
1 )
checkns cf || return
readp "请复制Cloudflare的Global API Key：" GAK
export CF_Key="$GAK"
readp "请输入登录Cloudflare的注册邮箱地址：" CFemail
export CF_Email="$CFemail"
acme_issue "$ym" "--dns dns_cf" "" "--server letsencrypt --insecure"
;;
2 )
checkns dp || return
readp "请复制腾讯云DNSPod的DP_Id：" DPID
export DP_Id="$DPID"
readp "请复制腾讯云DNSPod的DP_Key：" DPKEY
export DP_Key="$DPKEY"
acme_issue "$ym" "--dns dns_dp" "" "--server letsencrypt --insecure"
;;
3 )
checkns ali || return
readp "请复制阿里云Aliyun的Ali_Key：" ALKEY
export Ali_Key="$ALKEY"
readp "请复制阿里云Aliyun的Ali_Secret：" ALSER
export Ali_Secret="$ALSER"
acme_issue "$ym" "--dns dns_ali" "" "--server letsencrypt --insecure"
;;
0 ) return;;
* ) red "输入错误，已返回上一级" && return;;
esac
installCA
checktls
}

ACMEDNScheck(){
# DNS-01验证走域名的NS记录+服务商API，不依赖本机出口IP，
# 所以不需要像旧版那样为了测到"真实IP"而临时关停WARP
ACMEDNS
}

ACMEstandaloneDNScheck(){
wgcfv6=$(curl -s6m6 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
wgcfv4=$(curl -s4m6 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
ACMEstandaloneDNS
else
systemctl stop wg-quick@wgcf >/dev/null 2>&1
kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
ACMEstandaloneDNS
systemctl start wg-quick@wgcf >/dev/null 2>&1
systemctl restart warp-go >/dev/null 2>&1
systemctl enable warp-go >/dev/null 2>&1
systemctl start warp-go >/dev/null 2>&1
fi
}

acme(){
first_install
mkdir -p "$CERT_DIR"
# 子菜单循环：申请完一个域名后停留在本菜单，可连续申请多个域名；选0返回主菜单。
# 关键修复：这里不再用 ( ... ) 子shell 包裹，否则 nginx_stop 的状态与恢复逻辑
# 会随子shell一起丢失，nginx 可能被永久停掉。
while true; do
echo
ab="1.选择独立80端口模式申请证书（仅需域名，小白推荐），安装过程中将临时释放80端口\n2.选择DNS API模式申请证书（需域名、ID、Key），自动识别单域名与泛域名\n0.返回上一层\n 请选择："
readp "$ab" cd
case "$cd" in
1 ) acme3 && ACMEstandaloneDNScheck;;
2 ) acme3 && ACMEDNScheck;;
0 ) return;;
* ) red "输入错误，请重新选择" && sleep 1;;
esac
# 兜底：无论上面哪条路径返回，只要 nginx 是被本脚本停掉的，就恢复它
nginx_start
done
}

Certificate(){
acme_installed || { yellow "未安装acme.sh证书申请，无法执行"; return; }
green "Main_Domain下显示的域名就是已申请成功的域名证书，Renew下显示对应域名证书的自动续期时间点"
"$ACME_BIN" --list
echo
readp "查询完毕，按回车返回主菜单……" temp
}

acmeshow(){
if acme_installed; then
caacme1=$(acme_domain_list | tr '\n' ' ')
if [[ -n "$caacme1" ]]; then
caacme="$caacme1"
else
caacme='无证书申请记录'
fi
else
caacme='未安装acme'
fi
}

#=======================================================================
# crontab 管理
# root 的 crontab 只有5个时间/命令字段，旧版多写的 root 字段会被当成命令名
#=======================================================================
cron_line(){
# 不加 --insecure：cron 无人值守执行，不应关闭对 ACME 服务端的 TLS 校验。
# 个别服务器缺根证书时可临时手工执行 --cron --insecure 排查。
echo "0 3 * * * $ACME_BIN --cron --home \"$ACME_HOME\" --auto-upgrade >> $LOGFILE 2>&1"
}

cronac(){
if ! have_cmd crontab; then
red "系统没有 crontab 命令，自动续期无法工作，请先安装 cron/cronie"
return 1
fi
local tmp
tmp=$(mktemp) || return 1
crontab -l 2>/dev/null | grep -v -- "--cron" | grep -vF "$CRON_MARK" > "$tmp"
echo "$CRON_MARK" >> "$tmp"
cron_line >> "$tmp"
if crontab "$tmp"; then
green "已安装每日自动续期任务：每天 03:00 检查一次，仅对临近到期的证书换证"
else
red "自动续期任务写入失败"
fi
rm -f "$tmp"
}

uncronac(){
have_cmd crontab || return 0
local tmp
tmp=$(mktemp) || return 1
crontab -l 2>/dev/null | grep -v -- "--cron" | grep -vF "$CRON_MARK" > "$tmp"
crontab "$tmp" >/dev/null 2>&1
rm -f "$tmp"
}

cron_status(){
if ! have_cmd crontab; then
red "系统缺少 crontab，自动续期不可用"
return
fi
if crontab -l 2>/dev/null | grep -qF -- "$ACME_BIN --cron"; then
green "自动续期任务状态：已安装"
crontab -l 2>/dev/null | grep -F -- "$ACME_BIN --cron"
else
red "自动续期任务状态：未安装（可到菜单4安装）"
fi
}

#=======================================================================
# 菜单3：手动一键续期（全部已申请域名）
#=======================================================================
acmerenew(){
acme_installed || { yellow "未安装acme.sh证书申请，无法执行"; return; }
green "以下显示的域名就是已申请成功的域名证书"
"$ACME_BIN" --list
echo
local domains d before after
domains=$(acme_domain_list)
if [[ -z "$domains" ]]; then
red "没有可续期的证书记录"
readp "按回车返回主菜单……" temp
return
fi
if ! ensure_port80_free; then
nginx_start
readp "按回车返回主菜单……" temp
return
fi
green "开始续期证书…………" && sleep 2
"$ACME_BIN" --cron -f
for d in $domains; do
# 用剩余天数变化判断是否真的换了证书，避免旧版"文件存在就报成功"的假成功
before=$(cert_days_left "$d")
ym="$d"
installCA >/dev/null 2>&1
after=$(cert_days_left "$d")
mkdir -p "$CERT_DIR"
if [[ -n "$after" && "$after" -gt 0 ]]; then
echo "$(date '+%F %T') $d 续期完成，剩余 $after 天" >> "$CERT_DIR/ca.log"
green "$d 证书可用，剩余 $after 天：/root/lshca/$d.crt"
if [[ -n "$before" && "$after" -gt "$before" ]]; then
green "  → 本次已实际更换为新证书"
else
yellow "  → 尚未到续期时间（剩余 $after 天），沿用原证书"
fi
else
red "$d 证书续期失败，请检查网络、域名解析或80端口占用"
fi
done
nginx_start
echo
readp "续期完毕，按回车返回主菜单……" temp
}

#=======================================================================
# 菜单4：批量域名自动续期配置
#=======================================================================
renew_parse_domains(){
# 逗号、分号、空白都当分隔符，同时支持每行一个域名。
# 旧版直接把 $ym 拿去判断，域名里的 * 会被 shell 当通配符展开，这里统一去掉通配前缀
tr ',;' '\n' <<< "$1" | tr -s ' \t' '\n' | sed -e 's/^\*\.//' -e 's/^\.//' -e 's/\.$//' | grep -v '^$' | sort -u
}

renew_confirm_domains(){
local input="$1" d
local list=() bad=()
while read -r d; do
[[ -z "$d" ]] && continue
if [[ "$d" == *.* && "$d" != *" "* && "$d" != *".."* && "$d" != -* ]]; then
list+=("$d")
else
bad+=("$d")
fi
done < <(renew_parse_domains "$input")
if [[ ${#bad[@]} -gt 0 ]]; then
red "以下输入不是合法域名，已忽略：${bad[*]}"
fi
[[ ${#list[@]} -eq 0 ]] && return 1
RENEW_TARGETS=("${list[@]}")
return 0
}

renew_show_status(){
local d days wr
printf '%-38s %-10s %-12s %s\n' "域名" "剩余天数" "验证方式" "证书文件"
for d in "$@"; do
days=$(cert_days_left "$d")
wr=$(cert_webroot_of "$d")
[[ -z "$days" ]] && days="无证书"
printf '%-38s %-10s %-12s %s\n' "$d" "$days" "$(webroot_label "$wr")" "$(cert_file_of "$d")"
done
}

renew_apply_hooks(){
local d ok=0 fail=0
for d in "$@"; do
if apply_renew_hooks "$d"; then
green "  $d ：续期钩子已写入（续期时自动停/启 nginx）"
ok=$((ok+1))
else
red "  $d ：续期钩子写入失败，请用菜单2确认证书是否存在"
fail=$((fail+1))
fi
done
echo
green "钩子写入结果：成功 $ok 个，失败 $fail 个"
}

renew_config(){
acme_installed || { red "未安装acme.sh证书申请，请先到菜单1申请证书"; return; }
first_install
mkdir -p "$CERT_DIR"
echo
green "==================== 批量域名自动续期配置 ===================="
yellow "请输入需要自动续期的域名，支持一次输入多个："
yellow "  · 每行一个域名，或在一行内用空格/逗号分隔"
yellow "  · 例：a.example.com b.example.com, c.example.com"
yellow "  · 泛域名请输入：*.example.com（脚本会自动去掉 * ）"
echo
yellow "输入完成后在空行按回车结束；直接回车则对当前全部已申请域名生效"
local input="" line
while IFS= read -r line; do
[[ -z "$line" ]] && break
input="$input $line"
done
if [[ -z "$(echo "$input" | tr -d ' \t')" ]]; then
yellow "未输入域名，自动使用当前全部已申请证书的域名"
input=$(acme_domain_list | tr '\n' ' ')
fi
if ! renew_confirm_domains "$input"; then
red "没有可用域名，已返回主菜单"
return
fi
echo
green "本次需要自动续期的域名共 ${#RENEW_TARGETS[@]} 个"
local d missing=0
for d in "${RENEW_TARGETS[@]}"; do
if acme_domain_exists "$d"; then
green "  [已签发] $d"
else
red "  [无记录] $d —— acme.sh 里没有该域名的申请记录，续期不会生效"
missing=$((missing+1))
fi
done
if [[ $missing -gt 0 ]]; then
yellow "提示：无记录的域名需要先到菜单1申请证书，之后再来这里配置自动续期"
fi
echo
renew_show_status "${RENEW_TARGETS[@]}"
echo
yellow "自动续期规则（与 acme.sh 上游一致）："
yellow "  Let's Encrypt 证书有效期 90 天，cron 每天检查，剩余 $RENEW_DAYS_DEFAULT 天时自动换证"
yellow "  也就是说“到期前自动续期”是在证书到期前约 $RENEW_DAYS_DEFAULT 天完成，而不是到期当天"
echo
yellow "80端口处理：独立80端口模式的证书，续期时 acme.sh 自动执行 pre-hook 停止 nginx，"
yellow "            换证并安装证书后自动执行 reloadcmd 拉起 nginx，无需人工干预"
yellow "            DNS API 模式的证书不占80端口，不需要停 nginx"
# 只有真正需要80端口的证书才做占用检查，避免 DNS 模式被无谓地停一次 nginx
local port80_needed=0
for d in "${RENEW_TARGETS[@]}"; do
case "$(cert_webroot_of "$d")" in
standalone|unknown) port80_needed=1 ;;
esac
done
if [[ $port80_needed -eq 1 ]] && { have_cmd ss || have_cmd lsof; }; then
local busy
nginx_stop
busy=$(port80_pids)
if [[ -n "$busy" ]]; then
yellow "注意：nginx 停掉后80端口仍被占用：$(port80_desc)"
yellow "      这些是 nginx 之外的进程，独立80端口模式的续期会失败，建议改用DNS API模式"
else
green "检查通过：停掉 nginx 后80端口可用，独立80端口模式可以正常自动续期"
fi
nginx_start
fi
if [[ $port80_needed -eq 0 ]]; then
green "本次域名均为 DNS API 模式，续期不占用80端口，nginx 无需停止"
fi
echo
readp "是否写入续期配置并安装自动续期任务？1:是 2:否：" rc
if [[ "$rc" != "1" ]]; then
yellow "已取消，未做任何改动"
return
fi
echo
green "正在写入续期钩子……"
renew_apply_hooks "${RENEW_TARGETS[@]}"
echo
cronac
echo
green "==================== 配置完成 ===================="
green "已纳入自动续期的域名：${RENEW_TARGETS[*]}"
cron_status
echo
yellow "续期日志：$LOGFILE"
yellow "各域名下次续期时间点可用菜单2查看"
echo
readp "按回车返回主菜单……" temp
}

#=======================================================================
# 菜单5：删除证书并卸载
#=======================================================================
uninstall(){
acme_installed || { yellow "未安装acme.sh证书申请，无法执行"; return; }
red "此操作将删除全部证书申请记录与 /root/lshca 下的证书文件"
readp "确认卸载请输入 yes（其他任意键取消）：" uy
if [[ "$uy" != "yes" ]]; then
yellow "已取消"
return
fi
# 旧版卸载前先 curl 重新安装一遍，纯属多余
"$ACME_BIN" --uninstall >/dev/null 2>&1
uncronac
rm -rf "$CERT_DIR"
rm -rf "$ACME_HOME"
sed -i '/acme.sh.env/d' "$HOME/.bashrc" 2>/dev/null
if acme_installed; then
red "acme.sh卸载失败"
else
green "acme.sh卸载完毕：证书记录、续期任务、证书文件均已清理"
fi
echo
readp "按回车返回主菜单……" temp
}

#=======================================================================
# 主菜单
#=======================================================================
start_menu(){
while true; do
clear
green "Acme-lsh脚本版本号 V2026.10.05（支持多域名证书管理与到期前自动续期）"
yellow "提示："
yellow "一、脚本不支持多IP的VPS，SSH登录的IP与VPS共网IP必须一致"
yellow "二、80端口模式仅支持单域名证书申请；申请与续期时会临时停止Nginx并在结束后自动恢复"
yellow "三、DNS API模式支持单域名与泛域名证书申请，不占用80端口"
yellow "四、泛域名申请前须设置一个名称为 * 字符的解析记录 (输入格式：*.一级/二级主域)"
yellow "五、已安装acme.sh后再次申请新域名证书时自动跳过重复安装，可连续申请多个域名"
yellow "六、自动续期由 acme.sh 的 cron 任务完成，请勿手工修改 ~/.acme.sh 下的续期配置"
yellow "公钥文件crt保存路径：/root/lshca/域名.crt"
yellow "密钥文件key保存路径：/root/lshca/域名.key"
if ! acme_installed; then
red "未检测到可用的 acme.sh"
yellow "探测结果："
printf '%s' "$ACME_DIAG" | sed 's/^/  /'
yellow "  （当前 HOME=$HOME  LE_WORKING_DIR=${LE_WORKING_DIR:-未设置}）"
yellow "先自动尝试安装一次……"
if acme3; then
green "acme.sh 已就绪：$ACME_BIN"
else
red "自动安装未成功，请查看上面的失败原因"
fi
fi
echo
red "========================================================================="
acmeshow
blue "当前已申请成功的证书（域名形式）："
yellow "$caacme"
echo
red "========================================================================="
green " 1. acme.sh申请letsencrypt ECC证书（支持80端口模式与DNS API模式） "
green " 2. 查询已申请成功的域名及自动续期时间点 "
green " 3. 手动一键证书续期（全部域名） "
green " 4. 批量域名自动续期配置（到期前自动换证） "
green " 5. 删除证书并卸载一键ACME证书申请脚本 "
green " 0. 退出 "
echo
readp "请输入数字:" NumberInput
case "$NumberInput" in
1 ) acme;;
2 ) Certificate;;
3 ) acmerenew;;
4 ) renew_config;;
5 ) uninstall;;
0 ) green "已退出Acme-lsh脚本" && exit 0;;
* ) red "输入错误，请重新输入" && sleep 1;;
esac
done
}

start_menu
