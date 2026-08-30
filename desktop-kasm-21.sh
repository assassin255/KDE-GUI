#!/usr/bin/env bash
set -Eeuo pipefail

PORT="8444"
USER="kde"
GEOMETRY="1920x1080"
PINGGY_TOKEN=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
log() { printf '%s[%s]%s %s\n' "$GREEN" "$1" "$RESET" "$2" >&2; }
info() { log "INFO" "$1"; }
ok() { log " OK " "$1"; }
err() { log "ERR " "$1"; exit 1; }

require_root() { [[ "$(id -u)" -eq 0 ]] || err "Chay bang root."; }

# Cai cac goi trong danh sach, tu dong bo qua goi khong co trong repo
# (khac nhau giua cac distro/moi truong: CodeSandbox, Colab, v.v.)
apt_install() {
    local pkg avail=() skipped=()
    for pkg in "$@"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            avail+=("$pkg")
        else
            skipped+=("$pkg")
        fi
    done
    if [[ ${#skipped[@]} -gt 0 ]]; then
        info "Bo qua goi khong co trong repo: ${skipped[*]}"
    fi
    if [[ ${#avail[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${avail[@]}" >> "$INSTLOG" 2>&1 || \
            info "Mot vai goi cai loi (xem $INSTLOG), tiep tuc..."
    fi
}

install() {
    require_root
    source /etc/os-release 2>/dev/null || err "Khong ho tro distro."
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    [[ "$ARCH" == "x86_64" ]] && ARCH=amd64

    [[ $(id -u "$USER" 2>/dev/null) ]] || useradd -m -s /bin/bash -c "KDE" "$USER"
    echo "${USER}:kde1234" | chpasswd
    mkdir -p /home/$USER/.vnc
    chown -R $USER:$USER /home/$USER/.vnc

    apt-get update -y > /tmp/desktop-kasm-install.log 2>&1 || true
    INSTLOG="/tmp/desktop-kasm-install.log"

    info "Cai KDE (cot loi)..."
    apt_install plasma-desktop kwin-x11 xorg xserver-xorg-core xserver-xorg-input-libinput \
        xinit dbus-x11 breeze breeze-cursor-theme gtk2-engines-pixbuf \
        libgl1-mesa-dri libegl-mesa0 libglx-mesa0 mesa-utils ssl-cert openssl expect

    if ! command -v startplasma-x11 >/dev/null 2>&1; then
        echo ""
        echo "----- $INSTLOG (50 dong cuoi) -----"
        tail -50 "$INSTLOG"
        echo "-----------------------------------"
        err "Cai KDE that bai (khong thay startplasma-x11). Xem log tren de biet nguyen nhan."
    fi

    info "Cai them goi khong bat buoc (theme GNOME, v.v.)..."
    apt_install qgnomeplatform-qt5 qgnomeplatform-qt6 adwaita-qt

    info "Cai them QML modules cho Application Launcher..."
    apt_install qml-module-org-kde-kirigami2 plasma-framework \
        qml-module-org-kde-kquickcontrolsaddons qml-module-org-kde-kcoreaddons \
        qml-module-org-kde-kitemmodels qml-module-qt-labs-platform \
        qml-module-qtquick-controls qml-module-qtquick-controls2 \
        qml-module-qtquick-layouts qml-module-qtgraphicaleffects \
        qml-module-qtquick-window2 plasma-workspace plasma-pa

    info "Cai Google Chrome..."
    if [[ "$ARCH" == "amd64" ]]; then
        wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb || true
        if [[ -s /tmp/chrome.deb ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/chrome.deb > /dev/null 2>&1 || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -f > /dev/null 2>&1 || true
            rm -f /tmp/chrome.deb
        fi
    fi
    if ! command -v google-chrome-stable >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
        info "Google Chrome khong cai duoc, dung Chromium thay the..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium > /dev/null 2>&1 || true
    fi

    info "Tao SSL snakeoil cert..."
    mkdir -p /etc/ssl/private /etc/ssl/certs
    if [[ ! -s /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
        if command -v make-ssl-cert >/dev/null 2>&1; then
            make-ssl-cert generate-default-snakeoil --force-overwrite > /dev/null 2>&1
        fi
    fi
    if [[ ! -s /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/ssl/private/ssl-cert-snakeoil.key \
            -out /etc/ssl/certs/ssl-cert-snakeoil.pem \
            -subj "/CN=localhost" > /dev/null 2>&1
    fi
    chgrp ssl-cert /etc/ssl/private/ssl-cert-snakeoil.key 2>/dev/null || true
    chmod 640 /etc/ssl/private/ssl-cert-snakeoil.key 2>/dev/null || true
    usermod -aG ssl-cert "$USER" 2>/dev/null || true

    info "Cai KasmVNC..."
    if ! command -v kasmvncserver >/dev/null 2>&1; then
        info "Cai san cac thu vien perl phu thuoc..."
        apt_install libswitch-perl libyaml-tiny-perl libhash-merge-simple-perl \
            liblist-moreutils-perl libtry-tiny-perl libdatetime-timezone-perl \
            libdatetime-perl

        local deb="/tmp/kasmvnc.deb"
        local real_codename="${VERSION_CODENAME:-}"
        local codename codenames="bookworm jammy focal noble bullseye"
        # Uu tien thu dung codename that cua he thong truoc
        if [[ -n "$real_codename" ]]; then
            codenames="$real_codename $codenames"
        fi
        for codename in $codenames; do
            if curl -fsSL --max-time 300 -o "$deb" \
                "https://github.com/kasmtech/KasmVNC/releases/download/v1.3.3/kasmvncserver_${codename}_1.3.3_${ARCH}.deb" 2>/dev/null \
                && [[ -s "$deb" ]]; then
                info "Da tai kasmvncserver ban ${codename}, dang cai..."
                if dpkg -i "$deb" > "$INSTLOG.kasmvnc" 2>&1; then
                    break
                fi
                # Neu thieu dependency, thu fix nhung KHONG cho go mat goi vua cai
                if apt-get install -f -y >> "$INSTLOG.kasmvnc" 2>&1 && command -v kasmvncserver >/dev/null 2>&1; then
                    break
                fi
                info "Ban ${codename} khong tuong thich, thu ban khac..."
            fi
            rm -f "$deb"
        done
        rm -f "$deb"
        if ! command -v kasmvncserver >/dev/null 2>&1; then
            echo ""
            echo "----- $INSTLOG.kasmvnc (50 dong cuoi) -----"
            tail -50 "$INSTLOG.kasmvnc" 2>/dev/null
            echo "--------------------------------------------"
            err "Cai KasmVNC that bai (khong co ban .deb nao tuong thich)."
        fi
    fi

    info "Config software rendering..."
    cat > /home/$USER/.vnc/.env <<EOF
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export EGL_PLATFORM=x11
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export KWIN_COMPOSE=O2
export KWIN_OPENGL_DISABLE=1
export QT_XCB_GL_INTEGRATION=none
export QT_QUICK_BACKEND=software
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_DESKTOP=KDE
export DESKTOP_SESSION=plasma
export KDE_SESSION_VERSION=5
EOF
    chown $USER:$USER /home/$USER/.vnc/.env
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/10-sw.conf <<EOF
Section "Device"
    Identifier "Software"
    Driver     "modesetting"
    Option     "AccelMethod" "none"
EndSection
EOF

    info "Write xstartup..."
    cat > /home/$USER/.vnc/xstartup <<'XEOF'
#!/usr/bin/env bash
set -e
ENV_FILE="/home/kde/.vnc/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi
mkdir -p ~/.config
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
fi
exec dbus-run-session -- startplasma-x11
XEOF
    chmod 755 /home/$USER/.vnc/xstartup
    chown $USER:$USER /home/$USER/.vnc/xstartup

    info "Vo hieu hoa select-de.sh loi cua KasmVNC..."
    mkdir -p /usr/lib/kasmvncserver
    cat > /usr/lib/kasmvncserver/select-de.sh <<'DEEOF'
#!/bin/sh
exit 0
DEEOF
    chmod 755 /usr/lib/kasmvncserver/select-de.sh

    ok "CAI DAT XONG"
}

start_vnc() {
    require_root

    info "Dung cac phien KasmVNC cu (neu co)..."
    su - "$USER" -c "kasmvncserver -kill :1" > /dev/null 2>&1 || true
    pkill -9 -u "$USER" -f Xvnc 2>/dev/null || true
    pkill -9 -u "$USER" -f kasmvncserver 2>/dev/null || true
    sleep 1
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 /home/$USER/.kasmpasswd 2>/dev/null || true

    info "Khoi dong KasmVNC..."
    LOG="/tmp/desktop-kasmvnc.log"
    EXP="/tmp/kasm-setup.exp"

    cat > "$EXP" <<EXPEOF
#!/usr/bin/expect -f
set timeout 30
spawn su - $USER -c "kasmvncserver :1 -geometry $GEOMETRY -xstartup /home/$USER/.vnc/xstartup -rfbport $PORT -interface 0.0.0.0 -httpd /usr/share/kasmvnc/www -sslOnly 0 -DisableBasicAuth 1"
expect {
    "Provide selection number" { send "1\r"; exp_continue }
    "Enter username" { send "\r"; exp_continue }
    -re {(?i)(password|verify|retype|re-?enter|again)} { send "kde1234\r"; exp_continue }
    -re {(?i)view.?only} { send "n\r"; exp_continue }
    -re {(?i)desktop environment} { send "1\r"; exp_continue }
    timeout { send_user "\n===EXPECT_TIMEOUT===\n"; exit 1 }
    eof
}
EXPEOF
    chmod +x "$EXP"

    (expect "$EXP" > "$LOG" 2>&1) &

    for i in $(seq 1 30); do
        sleep 1
        if pgrep -u "$USER" -f Xvnc >/dev/null 2>&1; then
            IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || echo "")
            [[ -z "$IP" ]] && IP=$(hostname -I | awk '{print $1}')
            ok "KasmVNC dang chay"
            echo ""
            echo -e "  ${BOLD}Desktop:${RESET} http://$IP:$PORT/"
            echo -e "  ${BOLD}User:${RESET} $USER"
            echo -e "  ${BOLD}Password:${RESET} kde1234"
            echo ""
            return 0
        fi
    done

    echo ""
    echo "----- $LOG -----"
    cat "$LOG" 2>/dev/null
    echo "-----------------"
    err "KasmVNC khong khoi dong."
}

start_pinggy() {
    pkill -f "ssh.*pinggy" 2>/dev/null || true
    sleep 1

    local target
    if [[ -n "$PINGGY_TOKEN" ]]; then
        target="${PINGGY_TOKEN}@a.pinggy.io"
        info "Khoi dong Pinggy tunnel (co token)..."
    else
        target="a.pinggy.io"
        info "Khoi dong Pinggy tunnel (che do khach)..."
    fi

    setsid bash -c "ssh -p 443 -R0:localhost:$PORT -o StrictHostKeyChecking=no -o BatchMode=yes -o ServerAliveInterval=30 ${target}" > /tmp/pinggy.log 2>&1 &
    disown 2>/dev/null || true

    for i in $(seq 1 15); do
        sleep 2
        local url
        url=$(grep -oP 'https://[^\s]+' /tmp/pinggy.log 2>/dev/null | grep -v 'dashboard.pinggy' | head -1)
        if [[ -n "$url" ]]; then
            ok "Pinggy: $url"
            echo ""
            echo -e "  ${BOLD}Truy cap tu xa:${RESET} $url"
            echo ""
            return 0
        fi
    done
    err "Pinggy khong khoi dong. Check /tmp/pinggy.log"
}

main() {
    echo ""
    info "=== KDE Plasma + KasmVNC ==="
    echo ""

    read -rp "Nhap Pinggy token (Enter de bo qua, dung che do khach): " INPUT_TOKEN || true
    if [[ -n "${INPUT_TOKEN:-}" ]]; then
        PINGGY_TOKEN="$INPUT_TOKEN"
    else
        PINGGY_TOKEN=""
        info "Bo qua token, dung Pinggy che do khach (guest)."
    fi
    echo ""

    install
    start_vnc
    start_pinggy
    echo ""
    ok "=== XONG ==="
    echo -e "  ${BOLD}User:${RESET} $USER"
    echo -e "  ${BOLD}Password:${RESET} kde1234"
    echo ""
}

main "$@"