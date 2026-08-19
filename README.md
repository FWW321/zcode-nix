# zcode-nix

[ZCode](https://zcode.z.ai)(智谱 GLM 官方 ADE,Agentic Development Environment,Electron 桌面端)的 Nix 打包与 [Home Manager](https://github.com/nix-community/home-manager) 模块。

> ⚠️ ZCode 上游闭源分发,包标记为 `unfree`,使用前需在配置里放行(`nixpkgs.config.allowUnfree = true`)。临时试用:`NIXPKGS_ALLOW_UNFREE=1 nix build --impure github:FWW321/zcode-nix`。

## 包

官方 `.deb` 解包 + `autoPatchelf`,不做任何二进制替换:

- chrome-sandbox 保持非 SUID(对齐上游 postinst 的 user namespaces 策略),依赖 NixOS 默认可用的 unprivileged userns;**不加 `--no-sandbox`** —— 对会执行任意 shell 命令的 agent 工具,sandbox 是实打实的安全边界
- launcher 自适应 Wayland/IME(`NIXOS_OZONE_WL` 时注入 ozone/wayland-ime flags)
- `tools/{bfs,rg,ugrep}` 保留捆绑:各带 sha256 完整性清单,替换有校验失败风险
- PATH 带 `desktop-file-utils`/`shared-mime-info`/`xdg-utils`:应用启动时自注册 `zcode://` scheme(OAuth 回跳依赖),缺工具则静默失败

```nix
# flake.nix
inputs.zcode-nix.url = "github:FWW321/zcode-nix";

# 仅装包(无 HM)
environment.systemPackages = [ inputs.zcode-nix.packages.${system}.zcode ];
# 或 overlay
nixpkgs.overlays = [ inputs.zcode-nix.overlays.default ];
```

## Home Manager 模块

`programs.zcode` 提供声明式管理:自定义模型供应商、MCP 服务器、subagents、skills、commands、全局 AGENTS.md。

```nix
inputs.zcode-nix.url = "github:FWW321/zcode-nix";

# 配置里
imports = [ inputs.zcode-nix.homeManagerModules.zcode ];

programs.zcode = {
  enable = true;

  # ── 自定义供应商 → ~/.zcode/v2/config.json ──
  providers.minimax = {
    kind = "anthropic";           # 端点协议,见下表
    baseURL = "https://api.minimax.chat/v1";
    apiKeyFile = "/run/secrets/minimax";   # 运行时读取,值不进 store
    models.MiniMax-M3 = { context = 204800; output = 32768; };
  };

  # ── MCP 服务器 → ~/.zcode/cli/config.json mcp.servers ──
  mcp.servers.fetch = {
    command = "uvx";
    args = [ "mcp-server-fetch" ];
    # env.GITHUB_TOKEN.file = "/run/secrets/gh";   # secret 同样不进 store
  };

  # ── subagent → ~/.zcode/agents/<name>.md ──
  agents.vision = {
    description = "识图专用 agent,凡图像理解一律委托";
    model = "custom:custom%3Aminimax:MiniMax-M3";  # 见 model 格式说明
    tools = [ "Read" "Glob" "Grep" ];   # 硬白名单;不设则继承全部工具
    prompt = ''
      你是视觉分析专家。只报告图中确实可见的内容…
    '';
  };

  # ── skills / commands / 全局 AGENTS.md ──
  skills = {
    # 单文件 | 目录 | 内联文本皆可
    my-skill = ./skills/my-skill;        # → ~/.zcode/skills/my-skill/
  };
  agentsMd = ./AGENTS.md;                # → ~/.zcode/AGENTS.md

  # agent 运行时 PATH 追加(skill 依赖的 CLI 等)
  extraPackages = [ pkgs.gh ];
};
```

### 部署机制(为什么不是全 symlink)

zcode 对 `~/.zcode/` 下资源的加载行为不同,模块按实测分流:

| 资源 | 方式 | 原因 |
|---|---|---|
| skills / AGENTS.md | `home.file` symlink | 只读资源,symlink 正常加载 |
| agents / commands | activation 拷贝普通文件 | **加载器拒收 symlink**(A/B 实证:同内容 symlink 被静默忽略);`cmp` 对账,GUI 手改会被下次 switch 还原;`.nix-managed` sidecar 记名 GC,GUI 自建的文件永不触碰 |
| providers / MCP | activation 对账注入 | `v2/config.json` 与 `cli/config.json` 是 GUI 活跃写区,整文件声明式会与 GUI 拉锯 → 只 upsert 带 `nixManaged` 标记的条目 + 回收已删除条目,`builtin:*` 槽位(oauth token 领地)与其余条目零接触 |

### 实测要点(3.8.1,均经 asar 源码或 A/B 验证)

- **providers 的 `kind` 决定请求路径**:`anthropic` → `/v1/messages`;`openai-compatible` → `/chat/completions`;`openai` → `/responses`(OpenAI Responses API)。智谱 coding 端点错配 `openai` 会 404
- **agent `model` 格式**:`custom:<URL 编码的 provider id>:<模型名>`,如 `custom:custom%3Aminimax:MiniMax-M3`(`:` 编码为 `%3A`)
- **agent frontmatter**:`name` + `description` 均必填,缺任一被**静默忽略**;`tools` 白名单一旦设置会连 MCP/技能工具一并禁掉
- **作用域**:agents 仅用户级(设置页的工作区切换是共享控件残留);skills/commands/MCP 双作用域,工作区级归项目仓库(`<项目>/.zcode/`),不在本模块职责内
- **生效时机**:providers/MCP 改动需重启应用(启动时快照);agents/skills 定义变更需新会话
- **`zcode://` scheme**:浏览器 OAuth 回跳依赖;HM 侧建议 `xdg.mimeApps.defaultApplications."x-scheme-handler/zcode" = "zcode.desktop"`(模块已内置)

## 测试

`nix flake check`(需 `NIXPKGS_ALLOW_UNFREE=1` + `--impure`,因上游 unfree)跑两条防线:

- **zcode-shellcheck**:模块内嵌的全部 activation 脚本(渲染后的 `.data`)+ 校验器 + 测试本体过 shellcheck
- **zcode-activation-dryrun**:真实 HM 求值渲染的 activation,打在沙箱 HOME 的仿真 GUI 状态上,断言四条性质——agents/commands 拷贝落位、sidecar GC(GUI 自建文件零接触)、providers/mcp 对账(builtin/`oauth` 槽位零接触、secret 渲染)、二跑幂等

另:`normalizeSkillSource` 在 build 期校验每个 skill 源的 SKILL.md frontmatter(缺 name/description 直接构建失败——这类 skill 会被客户端**静默拒载**,不能等运行时发现)。

## 更新

上游版本由 GitHub Actions 每日自动跟踪(也可 Actions → update → Run workflow 手动触发):探测到新版 → 构建验证 → bot 提交 `zcode: bump to <version>`。major 跳版(如 4.0.0)超出探测范围,需手动改 source.json 锚点后跑 `./pkgs/zcode/update.sh`(探测逻辑见脚本头注释:上游 CDN 无 latest 指针、官网版本列表滞后、版本会跳号)。

## 致谢

- 打包骨架参考 nixpkgs `chatgpt` 包([PR #551713](https://github.com/NixOS/nixpkgs/pull/551713))
- PATH 里 `desktop-file-utils` 的必要性参考 [Redskaber/zcode](https://github.com/Redskaber/zcode) 的发现
