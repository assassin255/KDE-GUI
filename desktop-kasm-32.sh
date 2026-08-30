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

require_root() { [[ "$(id -u)" -eq 0 ]] || err "Chạy bằng root."; }

# Cài các gói trong danh sách, tự động bỏ qua gói không có trong repo
# (khác nhau giữa các distro/môi trường: CodeSandbox, Colab, v.v.)
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
        info "Bỏ qua gói không có trong repo: ${skipped[*]}"
    fi
    if [[ ${#avail[@]} -gt 0 ]]; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${avail[@]}" >> "$INSTLOG" 2>&1; then
            info "Một vài gói cài lỗi (xem $INSTLOG), đang dọn dẹp..."
            apt-get install -f -y >> "$INSTLOG" 2>&1 || true
        fi
    fi
}

install() {
    require_root
    source /etc/os-release 2>/dev/null || err "Không hỗ trợ distro."
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    [[ "$ARCH" == "x86_64" ]] && ARCH=amd64

    [[ $(id -u "$USER" 2>/dev/null) ]] || useradd -m -s /bin/bash -c "KDE" "$USER"
    echo "${USER}:kde1234" | chpasswd
    mkdir -p /home/$USER/.vnc
    chown -R $USER:$USER /home/$USER/.vnc

    apt-get update -y > /tmp/desktop-kasm-install.log 2>&1 || true
    INSTLOG="/tmp/desktop-kasm-install.log"

    if [[ "${ID:-}" == "ubuntu" ]]; then
        info "Bật repo universe/multiverse (cần cho VLC, GIMP, Steam...)..."
        if ! command -v add-apt-repository >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common >> "$INSTLOG" 2>&1 || true
        fi
        add-apt-repository -y universe >> "$INSTLOG" 2>&1 || true
        add-apt-repository -y multiverse >> "$INSTLOG" 2>&1 || true
        apt-get update -y >> "$INSTLOG" 2>&1 || true
    fi

    info "Cấp quyền sudo cho user $USER..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo >> "$INSTLOG" 2>&1 || true
    usermod -aG sudo "$USER" 2>/dev/null || true
    echo "${USER} ALL=(ALL) PASSWD: ALL" > /etc/sudoers.d/90-$USER
    chmod 440 /etc/sudoers.d/90-$USER

    info "Cài KDE (cốt lõi)..."
    apt_install plasma-desktop kwin-x11 xorg xserver-xorg-core xserver-xorg-input-libinput \
        xinit dbus-x11 breeze breeze-cursor-theme gtk2-engines-pixbuf \
        libgl1-mesa-dri libegl-mesa0 libglx-mesa0 mesa-utils ssl-cert openssl expect \
        dolphin dolphin-plugins kio-extras ffmpegthumbs kimageformat-plugins \
        udisks2 file-roller ark konsole xterm kate gwenview spectacle \
        systemsettings okular pulseaudio \
        fonts-noto fonts-noto-color-emoji fonts-liberation fonts-dejavu

    if ! command -v startplasma-x11 >/dev/null 2>&1; then
        echo ""
        echo "----- $INSTLOG (50 dòng cuối) -----"
        tail -50 "$INSTLOG"
        echo "-----------------------------------"
        err "Cài KDE thất bại (không thấy startplasma-x11). Xem log trên để biết nguyên nhân."
    fi

    info "Cài thêm gói không bắt buộc (theme GNOME, v.v.)..."
    apt_install qgnomeplatform-qt5 qgnomeplatform-qt6 adwaita-qt

    info "Cài phần mềm cơ bản (văn phòng, media, tiện ích)..."
    apt_install libreoffice-writer libreoffice-calc libreoffice-impress \
        vlc gimp kcalc filelight p7zip-full unzip zip \
        htop neofetch net-tools iputils-ping

    info "Cài thêm QML modules cho Application Launcher..."
    apt_install qml-module-org-kde-kirigami2 plasma-framework \
        qml-module-org-kde-kquickcontrolsaddons qml-module-org-kde-kcoreaddons \
        qml-module-org-kde-kitemmodels qml-module-qt-labs-platform \
        qml-module-qtquick-controls qml-module-qtquick-controls2 \
        qml-module-qtquick-layouts qml-module-qtgraphicaleffects \
        qml-module-qtquick-window2 plasma-workspace plasma-pa

    info "Cài Google Chrome..."
    if [[ "$ARCH" == "amd64" ]]; then
        wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb || true
        if [[ -s /tmp/chrome.deb ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/chrome.deb > /dev/null 2>&1 || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -f > /dev/null 2>&1 || true
            rm -f /tmp/chrome.deb
        fi
    fi
    if ! command -v google-chrome-stable >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
        info "Google Chrome không cài được, dùng Chromium thay thế..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium > /dev/null 2>&1 || true
    fi

    info "Tạo SSL snakeoil cert..."
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

    info "Cài KasmVNC..."
    info "Cài sẵn các thư viện perl phụ thuộc..."
    apt_install libswitch-perl libyaml-tiny-perl libhash-merge-simple-perl \
        liblist-moreutils-perl libtry-tiny-perl libdatetime-timezone-perl \
        libdatetime-perl

    if ! command -v kasmvncserver >/dev/null 2>&1; then
        local deb="/tmp/kasmvnc.deb"
        local real_codename="${VERSION_CODENAME:-}"
        local codename codenames="bookworm jammy focal noble bullseye"
        # Ưu tiên thử đúng codename thật của hệ thống trước
        if [[ -n "$real_codename" ]]; then
            codenames="$real_codename $codenames"
        fi
        for codename in $codenames; do
            if curl -fsSL --max-time 300 -o "$deb" \
                "https://github.com/kasmtech/KasmVNC/releases/download/v1.3.3/kasmvncserver_${codename}_1.3.3_${ARCH}.deb" 2>/dev/null \
                && [[ -s "$deb" ]]; then
                info "Đã tải kasmvncserver bản ${codename}, đang cài..."
                if dpkg -i "$deb" > "$INSTLOG.kasmvnc" 2>&1; then
                    break
                fi
                # Nếu thiếu dependency, thử fix nhưng KHÔNG cho gỡ mất gói vừa cài
                if apt-get install -f -y >> "$INSTLOG.kasmvnc" 2>&1 && command -v kasmvncserver >/dev/null 2>&1; then
                    break
                fi
                info "Bản ${codename} không tương thích, thử bản khác..."
            fi
            rm -f "$deb"
        done
        rm -f "$deb"
        if ! command -v kasmvncserver >/dev/null 2>&1; then
            echo ""
            echo "----- $INSTLOG.kasmvnc (50 dòng cuối) -----"
            tail -50 "$INSTLOG.kasmvnc" 2>/dev/null
            echo "--------------------------------------------"
            err "Cài KasmVNC thất bại (không có bản .deb nào tương thích)."
        fi
    fi

    info "Cấu hình software rendering..."
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

    info "Ghi xstartup..."
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

    info "Vô hiệu hoá select-de.sh lỗi của KasmVNC..."
    mkdir -p /usr/lib/kasmvncserver
    cat > /usr/lib/kasmvncserver/select-de.sh <<'DEEOF'
#!/bin/sh
exit 0
DEEOF
    chmod 755 /usr/lib/kasmvncserver/select-de.sh

    info "Cập nhật cache menu ứng dụng KDE..."
    su - "$USER" -c "kbuildsycoca5 --noincremental" > /dev/null 2>&1 || \
    su - "$USER" -c "kbuildsycoca6 --noincremental" > /dev/null 2>&1 || true
    update-desktop-database /usr/share/applications 2>/dev/null || true

    ok "CÀI ĐẶT XONG"
}

install_wine_steam() {
    require_root
    info "Cài Wine (chạy .exe trực tiếp)..."
    apt_install wine winetricks winbind cabextract

    # wine32/i386 hay bi loi tren cac ban Ubuntu moi (24.04+), tach rieng
    # de khong lam ket cac goi khac neu that bai
    dpkg --add-architecture i386 2>/dev/null || true
    apt-get update -y >> "$INSTLOG" 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wine32 wine64 \
        >> "$INSTLOG" 2>&1; then
        info "wine32 khong tuong thich voi distro nay, don dep va bo qua..."
        apt-get install -f -y >> "$INSTLOG" 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-broken >> "$INSTLOG" 2>&1 || true
    fi

    info "Cài Steam client (để dùng Proton thật)..."
    apt_install steam-installer steam
    if ! command -v steam >/dev/null 2>&1; then
        info "Steam không có trong repo mặc định, thử tải .deb chính thức..."
        wget -q -O /tmp/steam.deb https://cdn.fastly.steamstatic.com/client/installer/steam.deb || true
        if [[ -s /tmp/steam.deb ]]; then
            dpkg -i /tmp/steam.deb > "$INSTLOG.steam" 2>&1 || true
            apt-get install -f -y >> "$INSTLOG.steam" 2>&1 || true
        fi
        rm -f /tmp/steam.deb
    fi
    if command -v steam >/dev/null 2>&1; then
        ok "Steam đã cài. Đăng nhập Steam -> chuột phải game -> Properties -> Compatibility -> bật Proton."
    else
        info "Không cài được Steam (có thể do giới hạn mạng/repo). Wine vẫn dùng được để chạy .exe."
    fi
}

install_android_studio() {
    require_root
    info "Cài Java (cần cho Android Studio)..."
    apt_install openjdk-17-jdk

    info "Tải Android Studio..."
    local AS_URL="https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2024.2.1.12/android-studio-2024.2.1.12-linux.tar.gz"
    local AS_TAR="/tmp/android-studio.tar.gz"
    wget -q -O "$AS_TAR" "$AS_URL" || true
    if [[ -s "$AS_TAR" ]]; then
        rm -rf /opt/android-studio
        tar -xzf "$AS_TAR" -C /opt/ > /dev/null 2>&1 || true
        rm -f "$AS_TAR"
    fi
    if [[ -x /opt/android-studio/bin/studio.sh ]]; then
        ln -sf /opt/android-studio/bin/studio.sh /usr/local/bin/android-studio
        cat > /usr/share/applications/android-studio.desktop <<'DESKEOF'
[Desktop Entry]
Name=Android Studio
Exec=/opt/android-studio/bin/studio.sh %f
Icon=/opt/android-studio/bin/studio.png
Type=Application
Categories=Development;IDE;
Terminal=false
DESKEOF
        ok "Android Studio đã cài ở /opt/android-studio"
    else
        info "Tải Android Studio thất bại (có thể do link tải đã đổi). Bỏ qua."
        return 0
    fi

    info "Cài Android SDK cmdline-tools + emulator + system image..."
    local SDK_ROOT="/opt/android-sdk"
    mkdir -p "$SDK_ROOT/cmdline-tools"
    local CT_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    wget -q -O /tmp/cmdline-tools.zip "$CT_URL" || true
    if [[ -s /tmp/cmdline-tools.zip ]]; then
        unzip -q -o /tmp/cmdline-tools.zip -d /tmp/ct-extract > /dev/null 2>&1 || true
        rm -rf "$SDK_ROOT/cmdline-tools/latest"
        mv /tmp/ct-extract/cmdline-tools "$SDK_ROOT/cmdline-tools/latest" 2>/dev/null || true
        rm -rf /tmp/ct-extract /tmp/cmdline-tools.zip
    fi

    export ANDROID_SDK_ROOT="$SDK_ROOT"
    export ANDROID_HOME="$SDK_ROOT"
    local SDKMGR="$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
    if [[ -x "$SDKMGR" ]]; then
        echo "export ANDROID_SDK_ROOT=$SDK_ROOT" >> /etc/profile.d/android-sdk.sh
        echo "export ANDROID_HOME=$SDK_ROOT" >> /etc/profile.d/android-sdk.sh
        echo "export PATH=\$PATH:$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/platform-tools:$SDK_ROOT/emulator" >> /etc/profile.d/android-sdk.sh
        chmod +x /etc/profile.d/android-sdk.sh

        yes | "$SDKMGR" --licenses > /dev/null 2>&1 || true
        "$SDKMGR" --install "platform-tools" "platforms;android-34" \
            "system-images;android-34;google_apis;x86_64" \
            "emulator" "build-tools;34.0.0" > "$INSTLOG.sdk" 2>&1 || \
            info "Một phần SDK cài lỗi, xem $INSTLOG.sdk"

        info "Tạo máy ảo Android (AVD) mặc định..."
        echo "no" | "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager" create avd \
            -n Pixel_5 -k "system-images;android-34;google_apis;x86_64" \
            --device "pixel_5" -f > /dev/null 2>&1 || true

        chown -R $USER:$USER "$SDK_ROOT" 2>/dev/null || true

        if [[ -f "$SDK_ROOT/emulator/emulator" ]]; then
            ok "Android Emulator đã sẵn sàng. Chạy: emulator -avd Pixel_5 -gpu swiftshader_indirect"
            if [[ ! -e /dev/kvm ]]; then
                info "Không có /dev/kvm trong sandbox này -> emulator sẽ chạy bằng software rendering (chậm hơn máy thật)."
            fi
        fi
    else
        info "Không tải được Android cmdline-tools, bỏ qua bước cài SDK/emulator."
    fi
}

start_vnc() {
    require_root

    info "Dừng các phiên KasmVNC cũ (nếu có)..."
    su - "$USER" -c "kasmvncserver -kill :1" > /dev/null 2>&1 || true
    pkill -9 -u "$USER" -f Xvnc 2>/dev/null || true
    pkill -9 -u "$USER" -f kasmvncserver 2>/dev/null || true
    sleep 1
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 /home/$USER/.kasmpasswd 2>/dev/null || true

    info "Khởi động KasmVNC..."
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
            ok "KasmVNC đang chạy"
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
    err "KasmVNC không khởi động."
}

start_pinggy() {
    pkill -f "ssh.*pinggy" 2>/dev/null || true
    sleep 1

    local target
    if [[ -n "$PINGGY_TOKEN" ]]; then
        target="${PINGGY_TOKEN}@a.pinggy.io"
        info "Khởi động Pinggy tunnel (có token)..."
    else
        target="a.pinggy.io"
        info "Khởi động Pinggy tunnel (chế độ khách)..."
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
            echo -e "  ${BOLD}Truy cập từ xa:${RESET} $url"
            echo ""
            return 0
        fi
    done
    err "Pinggy không khởi động. Kiểm tra /tmp/pinggy.log"
}

main() {
    echo ""
    info "=== KDE Plasma + KasmVNC ==="
    echo ""

    read -rp "Nhập Pinggy token (Enter để bỏ qua, dùng chế độ khách): " INPUT_TOKEN || true
    if [[ -n "${INPUT_TOKEN:-}" ]]; then
        PINGGY_TOKEN="$INPUT_TOKEN"
    else
        PINGGY_TOKEN=""
        info "Bỏ qua token, dùng Pinggy chế độ khách (guest)."
    fi
    echo ""

    install
    if [[ "${SKIP_EXTRA:-0}" != "1" ]]; then
        install_wine_steam
        install_android_studio
    else
        info "SKIP_EXTRA=1: bỏ qua Wine/Steam/Android Studio."
    fi
    su - "$USER" -c "kbuildsycoca5 --noincremental" > /dev/null 2>&1 || \
    su - "$USER" -c "kbuildsycoca6 --noincremental" > /dev/null 2>&1 || true
    start_vnc
    start_pinggy
    echo ""
    ok "=== XONG ==="
    echo -e "  ${BOLD}User:${RESET} $USER"
    echo -e "  ${BOLD}Password:${RESET} kde1234"
    echo ""
}

main "$@"
