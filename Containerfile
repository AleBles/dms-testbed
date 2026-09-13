# dms-testbed: DankMaterialShell + Hyprland, niri, mangowc, sway, labwc and miracle-wm on Fedora 44,
# for testing DMS plugins in nested compositors. Repo choices mirror the DMS installer
# (core/internal/distros/fedora.go): COPR avengemedia/dms, avengemedia/danklinux,
# lionheartp/Hyprland; niri from Fedora; mangowm from Terra.
FROM registry.fedoraproject.org/fedora:44

RUN dnf -y install dnf-plugins-core && dnf clean all

# COPR repos, written directly (same format as `dnf copr enable` produces).
RUN for spec in "avengemedia/dms" "avengemedia/danklinux" "lionheartp/Hyprland"; do \
      owner=${spec%/*}; repo=${spec#*/}; \
      printf '%s\n' \
        "[copr:copr.fedorainfracloud.org:${owner}:${repo}]" \
        "name=Copr repo for ${repo} owned by ${owner}" \
        "baseurl=https://download.copr.fedorainfracloud.org/results/${owner}/${repo}/fedora-\$releasever-\$basearch/" \
        "type=rpm-md" \
        "skip_if_unavailable=True" \
        "gpgcheck=1" \
        "gpgkey=https://download.copr.fedorainfracloud.org/results/${owner}/${repo}/pubkey.gpg" \
        "repo_gpgcheck=0" \
        "enabled=1" \
        "enabled_metadata=1" \
        > "/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:${owner}:${repo}.repo"; \
    done

# Terra (provides mangowm), exactly as the DMS installer enables it.
RUN dnf -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release \
    && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-terra* \
    && dnf -y makecache \
    && dnf clean all

# Fail fast if any of the key packages cannot be resolved.
RUN for p in dms quickshell-git hyprland niri mangowm sway labwc miracle-wm wtype; do \
      dnf -y -q repoquery --latest-limit 1 "$p" | grep -q . || { echo "package not resolvable: $p" >&2; exit 1; }; \
    done

RUN dnf -y install --setopt=install_weak_deps=False \
      dms quickshell-git qt6-qtwayland matugen \
      hyprland niri mangowm sway labwc miracle-wm xwayland-satellite \
      kitty foot \
      mesa-dri-drivers mesa-libEGL mesa-libGLES mesa-libgbm mesa-vulkan-drivers \
      libxkbcommon xkeyboard-config wayland-utils \
      dbus-daemon procps-ng util-linux findutils gawk fontconfig jq \
      google-noto-sans-fonts google-noto-emoji-color-fonts \
    && dnf clean all


# Same uid as the host user so bind-mounted plugin dirs and the host Wayland socket are ours.
# grim: screenshots for `testbed.sh shot` via wlr-screencopy inside the nested compositor.
# wtype: `testbed.sh switch labwc N` drives labwc keybinds over the virtual-keyboard protocol.
# Noto Sans Mono: without any monospace font fontconfig hands terminals Noto Sans, and foot warns.
RUN dnf -y install --setopt=install_weak_deps=False grim wtype google-noto-sans-mono-fonts && dnf clean all

# Fedora's sway carries cap_sys_nice=ep as a file capability; a container's bounding set lacks it, so exec fails
# with EPERM. Nested sway does not need realtime scheduling; drop the capability.
RUN setcap -r /usr/bin/sway || true

RUN getent group render >/dev/null || groupadd -r render; \
    getent group video  >/dev/null || groupadd -r video; \
    getent group input  >/dev/null || groupadd -r input; \
    groupadd -g 1000 tester && useradd -u 1000 -g 1000 -G video,render,input -m -s /bin/bash tester \
    && su tester -c 'mkdir -p ~/.config/DankMaterialShell/plugins ~/.local/state/dms-testbed ~/.local/share ~/.cache'

RUN mkdir -p /tmp/xdg && chown tester /tmp/xdg && chmod 700 /tmp/xdg \
    && su tester -c 'export XDG_RUNTIME_DIR=/tmp/xdg; { echo "built: $(date -u +%FT%TZ)"; dms version 2>&1 | head -1; \
         qs --version 2>&1 | head -1; Hyprland --version 2>&1 | head -1; niri --version 2>&1 | head -1; \
         mango -v 2>&1 | head -1; sway --version 2>&1 | head -1; labwc --version 2>&1 | head -1; \
         miracle-wm --version 2>&1 | head -1; rpm -q dms quickshell-git hyprland niri mangowm sway labwc miracle-wm; }' > /etc/dms-testbed.version || true

COPY container/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY container/overlays /opt/testbed/overlays
RUN chmod +x /usr/local/bin/entrypoint.sh /opt/testbed/overlays/common/testbed-windows.sh /opt/testbed/overlays/miracle/launch.sh

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/tester \
    XDG_RUNTIME_DIR=/run/user/1000 \
    XDG_CONFIG_HOME=/home/tester/.config \
    XDG_STATE_HOME=/home/tester/.local/state \
    XDG_CACHE_HOME=/home/tester/.cache \
    XDG_DATA_HOME=/home/tester/.local/share \
    XDG_SESSION_TYPE=wayland \
    DMS_DISABLE_POLKIT=1 \
    DMS_DISABLE_CAVA=1 \
    DMS_LOG_LEVEL=info

USER 1000:1000
WORKDIR /home/tester
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
