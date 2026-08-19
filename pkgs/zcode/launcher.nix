# ZCode 启动器:Wayland/IME 自适应 flags(nixpkgs chatgpt launcher 同款)
# 比 chatgpt 少整段 writable-plugins staging:ZCode 未发现 Electron 改写捆绑
# 插件清单的问题;若实测出现同款症状,再按 chatgpt/launcher.nix 的
# mktemp staging + mv -T 原子发布模式补
{ writeShellApplication }:

writeShellApplication {
  name = "zcode-launcher";

  text = ''
    : "''${ZCODE_EXECUTABLE:?}"

    waylandFlags=()
    if [[ -n "''${NIXOS_OZONE_WL:-}" && -n "''${WAYLAND_DISPLAY:-}" ]]; then
      waylandFlags=(
        --ozone-platform-hint=auto
        --enable-features=WaylandWindowDecorations
        --enable-wayland-ime=true
      )
    fi

    exec "$ZCODE_EXECUTABLE" "''${waylandFlags[@]}" "$@"
  '';
}
