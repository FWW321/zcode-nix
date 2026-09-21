# ZCode(智谱 GLM 官方 ADE,Electron 桌面端)— 官方 .deb 解包 + autoPatchelf
# 骨架同 nixpkgs chatgpt 包(PR #551713),关键差异见下。
#
# 上游 2026-09 起开源(zai-org/ZCode,Apache-2.0),本包曾依赖的 asar 逆向
# 结论均已对照开源源码复核(引用见各处注释)。仍分发官方预编译 deb 而非源码
# 构建:官方渠道鉴权附带 1.5x 模型额度,自构建客户端没有。
#
# 与 chatgpt 包的三点差异(有意为之):
#   - 无独立 CLI 二进制:agent 是 resources/glm/zcode.cjs,跑在 Electron 内嵌
#     node(electron-builder.config.js 注释:Host 以 ELECTRON_RUN_AS_NODE 执行
#     `zcode.cjs app-server --stdio`),不存在"换 nixpkgs codex"的替换问题,
#     也不需要 writable-plugins staging
#   - deb 内 app-update.yml 的 feed 指向 localhost:8081 → 上游自己在 deb 构建里
#     就禁用了应用内更新(electron-builder.config.js 的 publish 占位注释:仅保留
#     generic provider 必需占位,避免产物携带可配置的旧 stable feed),
#     版本完全归本 flake 管,无对抗
#   - tools/{bfs,rg,ugrep} 保留捆绑、不换 nixpkgs 版:上游设计即"用户 PATH 版
#     优先,随包兜底"(electron-builder.config.js extraResources 注释),各带
#     .bundle-meta.json sha256 完整性清单,替换有校验失败风险;且 rg 本身静态
#     链接不污染闭包(与 chatgpt 换捆绑 node/rg/tectonic 的家规相反,方向是有意的)
#
# sandbox:chrome-sandbox 保持非 SUID(对齐上游 postinst 的 userns 策略:内核
# 支持 user namespaces 时 0755),依赖 NixOS 默认可用的 unprivileged userns;
# 不加 --no-sandbox —— 对会执行任意 shell 命令的 agent 工具,sandbox 是实打实的
# 安全边界,真跑不通时再作兜底考虑
{
  lib,
  stdenv,
  stdenvNoCC,
  callPackage,
  fetchurl,

  # hooks
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,

  # native build inputs
  dpkg,

  # build inputs:Electron 常备集 + deb Depends 一一对应
  # (多补无害,缺了 autoPatchelf 会硬报错,错误模式友好)
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  dconf,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  libgbm,
  libnotify,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxscrnsaver,
  libxtst,
  nspr,
  nss,
  pango,
  systemdLibs,
  util-linux, # libuuid(Depends: libuuid1)

  # runtime deps(Chromium 运行时 dlopen 的库,不走 NEEDED/autoPatchelf 路径)
  libGL,
  libpulseaudio,
  pipewire,
  vulkan-loader,
  # PATH 工具:ZCode 启动时自注册 zcode:// scheme(asar 实证调
  # update-desktop-database/xdg-mime/xdg-settings;缺工具则注册失败,
  # 借鉴 Redskaber/zcode 的发现)。HM 的 mimeApps 声明管浏览器侧,
  # 这三个管 app 侧自注册,双保险
  desktop-file-utils,
  shared-mime-info,
  xdg-utils,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "zcode";
  inherit (finalAttrs.passthru.source) version;

  src = fetchurl finalAttrs.passthru.source.src;

  strictDeps = true;

  # .deb 由 dpkg-deb 手工解包(sourceRoot=root,与 chatgpt 布局同构)
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" root
    runHook postUnpack
  '';
  sourceRoot = "root";

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    (lib.getLib stdenv.cc.cc) # libstdc++(pty.node/sshcrypto.node NEEDED)
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dconf
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libgbm
    libnotify
    libsecret
    libxkbcommon
    nspr
    nss
    pango
    systemdLibs
    util-linux
    libx11
    libxscrnsaver # Depends: libxss1
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxtst # Depends: libxtst6
    libxcb
  ];

  dontConfigure = true;
  dontBuild = true;

  # GApps wrap 由 postFixup 统一做在 launcher 上
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/opt" "$out/bin" "$out/share/applications"
    cp -r opt/ZCode "$out/opt/ZCode"

    # .desktop:Exec 重指 PATH 上的 launcher;MimeType(x-scheme-handler/zcode)
    # 原样保留 —— 浏览器 OAuth 登录回跳依赖这个关联(官方 FAQ)
    substitute usr/share/applications/zcode.desktop "$out/share/applications/zcode.desktop" \
      --replace-fail "Exec=/opt/ZCode/zcode" "Exec=zcode"
    cp -r usr/share/icons "$out/share/icons"

    install -Dm755 ${lib.getExe finalAttrs.passthru.launcher} "$out/bin/zcode"

    runHook postInstall
  '';

  postFixup = ''
    # ── 深链注册(zcode:// OAuth/支付回跳)与 wrapper 的配合 ──
    # 源码:packages/desktop/src/main/desktopLinuxDeepLinkRegistration.ts。
    # 3.14.1 起(已验该版本 asar 含新逻辑)注册流程先探测 XDG_DATA_DIRS 里的
    # 系统级 zcode.desktop:命中 → 按归属标记(Comment=ZCode Desktop App)清掉
    # 自己写过的用户级 ~/.local/share/applications/zcode.desktop 且不再写
    # —— 升级+GC 后的死链条目由 app 首启自愈,零用户级写入。
    # wrapGAppsHook 的 setup-hook 对存在 $out/share 的包一律追加
    # `--prefix XDG_DATA_DIRS : $out/share`(构建产物实证),包内 desktop 文件
    # 因此被 app 认作系统级条目,上面的自清理路径常规生效。
    # APPIMAGE 注入保留为降级防线:系统级探测失效(如绕过 wrapper 裸跑)时,
    # app 仍会写用户级条目,Exec 优先取 env.APPIMAGE —— 指向 wrapper 保证自写
    # 文件路由到完整 env(Wayland flags + PATH + LD_LIBRARY_PATH),而非裸二
    # 进制;electron-updater 的 AppImageUpdater 同名 env 仅 AppImage 模式读取,
    # deb 构建的 feed 已指占位 localhost(上游自禁更新),不受影响
    wrapProgram "$out/bin/zcode" \
      "''${gappsWrapperArgs[@]}" \
      --set ZCODE_EXECUTABLE "$out/opt/ZCode/zcode" \
      --set APPIMAGE "$out/bin/zcode" \
      --prefix PATH : ${
        lib.makeBinPath [
          desktop-file-utils
          shared-mime-info
          xdg-utils
        ]
      } \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          libGL
          libnotify
          libpulseaudio
          pipewire
          libsecret
          vulkan-loader
        ]
      }
  '';

  # Electron 大二进制不做 strip(chatgpt 同款)
  dontStrip = true;

  passthru = {
    updateScript = ./update.sh;
    sources = lib.importJSON ./source.json;
    source =
      finalAttrs.passthru.sources.${stdenvNoCC.hostPlatform.system}
        or (throw "zcode is not supported on ${stdenvNoCC.hostPlatform.system}");
    launcher = callPackage ./launcher.nix { };
  };

  meta = {
    description = "ZCode desktop app — Agentic Development Environment for GLM (Zhipu AI)";
    homepage = "https://zcode.z.ai";
    # 上游源码 Apache-2.0 + NOTICE(zai-org/ZCode,声明适用源码及构建产物),
    # deb 随包带 THIRD-PARTY-NOTICES.md 于 resources/;本包只重分发官方预编译
    # 产物,无附加条款限制。不从源码构建,理由见文件头注释
    license = lib.licenses.asl20;
    # TODO 提交 nixpkgs PR 时补: maintainers = [ lib.maintainers.<self> ];
    maintainers = [ ];
    platforms = lib.attrNames finalAttrs.passthru.sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "zcode";
  };
})
