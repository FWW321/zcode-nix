# ── programs.zcode:ZCode(智谱 GLM 官方 ADE)通用 Home Manager 模块 ──
#
# 只含机制,不含任何个人数据;你的供应商/MCP/agent 数据在自己的配置里
# 声明(用法示例见 README)。
# 选项词汇与上游 programs.opencode / programs.mcp 同族(业界形状):
#   - mcp.servers 用 command/url 业界形状(语义对齐 lib.hm.mcp / programs.mcp)
#   - agents/commands/skills 支持 内联文本 | 文件 path | 目录 path 三态
#   - providers 用 zcode schema 词汇(kind enum)
#
# 部署方式按 zcode 加载器行为分流(2026-08-20 实测):
#   - skills/AGENTS.md 是只读资源 → home.file symlink(声明式)
#   - agents/commands 是"用户可编辑文件",加载器拒收 symlink(A/B 实证:
#     同内容 symlink 被静默忽略)→ activation 拷贝成普通文件 + cmp 对账
#     + sidecar(.nix-managed)GC,GUI 自建文件永不触碰
#   - providers/mcp 写入 GUI 活跃 JSON → activation 对账(见下)
#
# 与 programs.opencode 的本质差异(保留 activation 对账的原因):
#   opencode.json 是纯声明式文件,上游模块可拥有整个文件;zcode 的
#   v2/config.json 与 cli/config.json 是 GUI 活跃写区,整文件声明式会
#   与 GUI 拉锯 → 对账注入(upsert 只管 nix 管辖条目):
#     - 只 upsert nix 管辖条目(打 nixManaged 标记),其余键零接触
#     - nixManaged 但已不在 options 的条目随 switch 整条回收(GC)
#     - builtin:* 槽位绝不碰(oauth 派生 token 的领地,实测 2026-08-19)
#     - 条目存在但无 nixManaged → GUI/用户所有,零接触
#
# zcode 协议坑(asar 实证,2026-08-19):kind 决定请求路径——
#   anthropic         → POST {baseURL}/v1/messages
#   openai-compatible → POST {baseURL}/chat/completions
#   openai            → POST {baseURL}/responses(OpenAI Responses API!)
# zhipu coding 端点错配 openai 会 404,详见 providers.<name>.kind 描述。
#
# secret 约定:apiKeyFile / env.<k>.file / headers.<k>.file 一律为运行时
# 可读的路径字符串(sops-nix / systemd-credentials 兼容),activation 时
# 渲染,值不进 store。
#
# 作用域(3.8.1 文档+asar 双证,2026-08-19):zcode 资源分用户级/工作区级两档,
# 本模块只管用户级 —— 工作区配置的宿主是项目仓库(<项目>/.zcode/),生命周期
# 跟 repo 走、要进 git、随 clone 分发,归 common/mcp-project.nix、skills-project.nix
# 那层项目渲染机制管,不属于 Home Manager 的声明域:
#   agents     仅用户级(~/.zcode/agents/);设置页的作用域切换是跨页共享控件,
#              subagents 页选中工作区即提示"暂不支持"(asar
#              workspaceScopeUnsupported 串),全代码只扫用户目录。
#              升级后若 GUI 放行工作区级,先在此复验再考虑扩展
#   skills     双作用域(~/.zcode/skills/ 与 <项目>/.zcode/skills/);
#              工作区级另有"同步 Skill 到远程主机"语义(远程开发)
#   commands   双作用域(asar user+workspace 双 DirectorySegments 实证)
#   MCP        双作用域(~/.zcode/cli/config.json 与 <项目>/.zcode/config.json,
#              同键 mcp.servers);注意:打开项目即自动连接其工作区 MCP
#              (安全面:clone 陌生仓库前先审 <项目>/.zcode/config.json);
#              用户级与工作区同名条目:用户级优先,不合并
#   providers  仅用户级(v2/config.json,无工作区概念)
#   AGENTS.md  用户级(~/.zcode/AGENTS.md,本模块管)+ 工作区(<项目>/AGENTS.md,
#              app 自读,不归模块管)
#
# 生效时机:zcode 运行时启动时快照配置,改 providers/mcp 后需重启应用;
# agents/skills 定义文件变更需新建会话(官方 subagents 文档)。
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.zcode;
  jq = "${pkgs.jq}/bin/jq";

  # ── providers:选项 → v2/config.json 对账 manifest ──
  providerManifest = pkgs.writeText "zcode-provider-manifest.json" (builtins.toJSON (
    lib.mapAttrsToList (name: p: {
      id = "custom:${name}";
      secretFile = p.apiKeyFile;
      template = {
        inherit name;
        inherit (p) kind;
        options.baseURL = p.baseURL;
        source = "custom";
        models = lib.mapAttrs (_: m: {
          limit = {
            inherit (m) context;
            inherit (m) output;
          };
        }) p.models;
      };
    }) cfg.providers
  ));

  # ── mcp:选项 → cli/config.json 对账 manifest ──
  # secret 以 @secret:<path>[:<prefix>] 占位,activation 渲染,不进 store
  toZcodeMcp =
    name: s:
    (
      if s.command != null then
        {
          type = "stdio";
          command = s.command;
          args = s.args;
          env = lib.mapAttrs (_: v: if v ? file then "@secret:${v.file}" else v) s.env;
        }
      else
        {
          type = "http";
          url = s.url;
          headers = lib.mapAttrs (
            _: h: if h ? file then "@secret:${h.file}:${h.prefix or ""}" else h
          ) s.headers;
        }
    )
    # zcode 的停用字段是 enable(非 enabled,官方 mcp-services 文档实证)
    // (lib.optionalAttrs (s.enabled == false) { enable = false; });

  mcpManifest = pkgs.writeText "zcode-mcp-manifest.json" (builtins.toJSON (
    lib.mapAttrsToList (name: s: {
      id = name;
      template = toZcodeMcp name s;
    }) cfg.mcp.servers
  ));

  # path-like 字符串技能源包成 build 期校验的 derivation
  # (programs.opencode 上游 normalizeSkill 同款)
  normalizeSkillSource =
    source:
    pkgs.runCommandLocal "zcode-skill" { } ''
      source=${lib.escapeShellArg (toString source)}
      if [[ -d "$source" ]]; then
        ln -s "$source" "$out"
      elif [[ -f "$source" ]]; then
        mkdir "$out"
        ln -s "$source" "$out/SKILL.md"
      else
        echo "zcode skill source must be a file or directory: $source" >&2
        exit 1
      fi
    '';

  # 技能三态 → home.file 条目(内联文本 | 单文件 | 目录)
  linkSkill =
    name: content:
    if lib.isPath content && lib.pathIsDirectory content then
      { ".zcode/skills/${name}" = { source = content; recursive = true; }; }
    else if lib.isPath content then
      { ".zcode/skills/${name}/SKILL.md".source = content; }
    else if lib.isString content && lib.hm.strings.isPathLike content then
      { ".zcode/skills/${name}" = { source = normalizeSkillSource content; recursive = true; }; }
    else
      { ".zcode/skills/${name}/SKILL.md".text = content; };

  # agents/commands 部署用 farm:zcode 加载器拒收 symlink(2026-08-20 A/B 实证:
  # 同内容 symlink 版被静默忽略、普通文件版显示),必须落成可写普通文件 →
  # activation 拷贝(cp 后是普通文件,GUI 可编辑,switch 对账还原)
  contentToFile =
    name: content:
    if lib.isPath content then content
    else if builtins.isAttrs content then renderAgent name content
    else pkgs.writeText "${name}.md" content;

  agentsFarm =
    if lib.isPath cfg.agents then cfg.agents
    else pkgs.linkFarm "zcode-agents" (
      lib.mapAttrsToList (n: c: {
        name = "${n}.md";
        path = contentToFile n c;
      }) cfg.agents
    );

  commandsFarm =
    if lib.isPath cfg.commands then cfg.commands
    else pkgs.linkFarm "zcode-commands" (
      lib.mapAttrsToList (n: c: {
        name = "${n}.md";
        path = if lib.isPath c then c else pkgs.writeText "${n}.md" c;
      }) cfg.commands
    );

  # extraPackages 经 symlinkJoin 并入 PATH(programs.opencode 同款)
  packageWithExtraPackages =
    if cfg.package != null && cfg.extraPackages != [ ] then
      pkgs.symlinkJoin {
        inherit (cfg.package) meta;
        name = "${lib.getName cfg.package}-wrapped-${lib.getVersion cfg.package}";
        paths = [ cfg.package ];
        preferLocalBuild = true;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/${cfg.package.meta.mainProgram} \
            --suffix PATH : ${lib.makeBinPath cfg.extraPackages}
        '';
      }
    else
      cfg.package;

  mcpServerModule = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "stdio server executable. Mutually exclusive with `url`.";
        example = "npx";
      };
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Arguments passed to `command` (local servers only).";
      };
      env = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.str
            (lib.types.submodule {
              options.file = lib.mkOption {
                type = lib.types.str;
                description = "Path to a file whose content is read at activation (secret).";
              };
            })
          ]
        );
        default = { };
        description = "Environment variables for the spawned server (local servers only).";
      };
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "HTTP(S) endpoint of a remote (HTTP/SSE) server. Mutually exclusive with `command`.";
      };
      headers = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.str
            (lib.types.submodule {
              options = {
                file = lib.mkOption {
                  type = lib.types.str;
                  description = "Path to a secret file whose content forms the header value.";
                };
                prefix = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  example = "Bearer ";
                  description = "String prepended to the file content.";
                };
              };
            })
          ]
        );
        default = { };
        description = "HTTP headers for remote servers.";
      };
      enabled = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether this server is enabled (rendered as zcode's `enable` field).";
      };
    };
  };

  providerModelModule = lib.types.submodule {
    options = {
      context = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Context window (tokens).";
      };
      output = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Max output tokens.";
      };
    };
  };

  providerModule = lib.types.submodule {
    options = {
      kind = lib.mkOption {
        type = lib.types.enum [
          "anthropic"
          "openai"
          "openai-compatible"
        ];
        description = ''
          Protocol kind, which selects the request path (asar-verified):
            `anthropic`         → `{baseURL}/v1/messages`
            `openai-compatible` → `{baseURL}/chat/completions`
            `openai`            → `{baseURL}/responses` (OpenAI Responses API)

          Note `openai` is NOT chat completions. Pointing a chat-completions
          endpoint (e.g. the zhipu coding-plan endpoint `/api/coding/paas/v4`)
          at `openai` yields 404.
        '';
      };
      baseURL = lib.mkOption {
        type = lib.types.strMatching "^https?://.+$";
        description = "Provider base URL; the request path is appended per `kind`.";
        example = "https://open.bigmodel.cn/api/anthropic";
      };
      apiKeyFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to a file containing the API key. Read at activation; the key never enters the store.";
        example = "/run/secrets/my_provider_key";
      };
      models = lib.mkOption {
        type = lib.types.attrsOf providerModelModule;
        default = { };
        description = "Model id → token limits.";
      };
    };
  };

  # zcode agent 颜色预设(asar 实证 26 色,GUI 选择器同源数组)
  agentColorType = lib.types.enum [
    "neutral" "stone" "zinc" "gray" "amber" "blue" "cyan" "emerald" "fuchsia"
    "green" "indigo" "lime" "orange" "pink" "purple" "red" "rose" "sky" "teal"
    "violet" "yellow" "mauve" "olive" "mist" "taupe"
  ];

  # ── agents:结构化定义 → frontmatter+正文 渲染 ──
  # YAML 标量渲染:字符串双引号转义(GUI 同款),bool/int 原样,列表 flow 风格
  yamlScalar =
    v:
    if lib.isBool v || lib.isInt v || lib.isFloat v then toString v
    else if lib.isList v then "[${lib.concatStringsSep ", " (map (x: "\"${lib.escape [ "\\" "\"" ] (toString x)}\"") v)}]"
    else if lib.isString v then "\"${lib.escape [ "\\" "\"" ] v}\""
    else throw "zcode agents: unsupported frontmatter value ${builtins.toJSON v}";

  renderAgent =
    name: def:
    let
      optionalFields = lib.filterAttrs (_: v: v != null) (
        lib.genAttrs [
          "model"
          "color"
          "thoughtLevel"
          "tools"
          "disallowedTools"
          "maxTurns"
          "injectAgentsMd"
          "mcpServers"
        ] (k: def.${k} or null)
      );
    in
    pkgs.writeText "${name}.md" (
      ''
        ---
        name: "${name}"
      ''
      # description 是必填项,必须显式渲染(缺它 zcode 静默忽略整个文件)
      + "description: ${yamlScalar def.description}\n"
      + (lib.concatStringsSep "" (lib.mapAttrsToList (k: v: "${k}: ${yamlScalar v}\n") optionalFields))
      + ''
        ---

        ${def.prompt}
      ''
    );

  # 内置工具名(官方 subagents 文档勾选列表实证);MCP 工具走 mcp__ 前缀,
  # 无法穷举,故非纯 enum 而是带描述的 str
  toolName = lib.types.strMatching "(^[A-Z][a-zA-Z]+$)|(^mcp__.+__.+$)";

  agentDefModule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = ''
          Shown to the main agent; it decides when to delegate to this
          subagent. Required — zcode silently ignores definition files
          without it (here it is a build error instead).
        '';
      };
      prompt = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "System prompt (the markdown body below the frontmatter).";
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Fully-qualified model reference, GUI-verified format:
          `custom:<url-encoded-provider-id>:<model>`, e.g.
          `custom:custom%3Aminimax:MiniMax-M3` (NOT the `<provider>/<model>`
          slash form the docs suggest). `null`/`inherit` follows the main
          agent's model.
        '';
      };
      color = lib.mkOption {
        type = lib.types.nullOr agentColorType;
        default = null;
        description = "Preset color marker (asar-verified 26-value enum shared with the GUI picker).";
      };
      thoughtLevel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Thinking effort; only effective with an explicit `model`. Kept a
          free string on purpose: the set of valid levels is model-dependent
          (GLM: low/high/max/nothink; GPT: low/medium/high/xhigh; DeepSeek V4:
          high/max) — an enum here would wrongly reject valid combinations.
        '';
      };
      tools = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf toolName);
        default = null;
        description = ''
          Allowed tools; `null` inherits all. Built-in tool names
          (asar-verified): Read, Grep, Glob, Bash, Edit, Write, WebFetch,
          WebSearch, TodoWrite. MCP tools need full names
          (`mcp__<server>__<tool>`); wildcards are ignored by zcode.
        '';
      };
      disallowedTools = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Disallowed tools.";
      };
      maxTurns = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Max turns per invocation.";
      };
      injectAgentsMd = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether to inject AGENTS.md (default true since v3.7.1).";
      };
      mcpServers = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "MCP server names this subagent depends on (exact match; calls fail when not connected).";
      };
    };
  };
in
{
  options.programs.zcode = {
    enable = lib.mkEnableOption "zcode";

    package = lib.mkPackageOption pkgs "zcode" { nullable = true; };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages available to ZCode (e.g. skill runtime tools), via PATH.";
    };

    agentsMd = lib.mkOption {
      # package 分支收 writeText 之类的 derivation(source 接受,toString 即 store path)
      type = lib.types.either lib.types.lines (lib.types.either lib.types.path lib.types.package);
      default = "";
      description = ''
        Global rules written to {file}`~/.zcode/AGENTS.md`.
        Either inline text, a file path, or a derivation producing the file.
      '';
    };

    agents = lib.mkOption {
      type =
        with lib.types;
        either (attrsOf (either lines (either path agentDefModule))) path;
      default = { };
      description = ''
        Subagent definitions written to {file}`~/.zcode/agents/`.
        Attrset values are inline text, a file path, or a structured
        definition (see `agentDefModule` options; the module renders the
        frontmatter, `description` becomes a build-time requirement instead
        of zcode's silent ignore). Alternatively a single path to a directory
        of agent files.

        Scope: user-level only as of 3.8.1 — the settings page shows a
        workspace scope toggle, but it is a shared widget; asar strings
        confirm `暂不支持工作区级创建或编辑` and only `~/.zcode/agents/`
        is scanned. Re-verify on upgrade if workspace agents ship.

        Deployment: plain-file copies (the loader rejects symlinks,
        A/B-verified 2026-08-20), reconciled on each switch — GUI edits to
        these files are reverted; GUI-created agent files coexist untouched.

        Hand-written files must include both `name` and `description` in the
        frontmatter — missing either is silently ignored by zcode. The
        `model` format is `custom:<url-encoded-provider-id>:<model>`, e.g.
        `custom:custom%3Aminimax:MiniMax-M3`. Keep filename and frontmatter
        `name` in sync: the registry dedupes by frontmatter name — a second
        file declaring an existing name is silently dropped (verified
        2026-08-20). The module always derives both from the attrset key.
        MCP tools in `tools` need full
        names (`mcp__<server>__<tool>`); wildcards are ignored. Changes
        require a new session to take effect; the agent registry is snapshotted
        at process start, so a full app restart is the reliable path after
        editing definition files (verified 2026-08-20: new session alone did
        not pick up a fixed file until restart).
      '';
    };

    commands = lib.mkOption {
      type = lib.types.either (lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path)) lib.types.path;
      default = { };
      description = ''
        Custom commands written to {file}`~/.zcode/commands/`.
        Same shape as {option}`programs.zcode.agents`.
      '';
    };

    skills = lib.mkOption {
      type =
        with lib.types;
        either (attrsOf (either lines (either path str))) path;
      default = { };
      description = ''
        Skills written to {file}`~/.zcode/skills/`.
        Attrset values: inline text, a file path (used as `SKILL.md`), a
        directory path, or a store-path string; alternatively a single path to
        a directory of skill folders.
      '';
    };

    mcp = {
      servers = lib.mkOption {
        type = lib.types.attrsOf mcpServerModule;
        default = { };
        description = ''
          MCP servers reconciled into `mcp.servers` of
          {file}`~/.zcode/cli/config.json` (upsert + GC of nixManaged entries;
          every other key in that file is left to the GUI).
        '';
      };
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf providerModule;
      default = { };
      description = ''
        Custom model providers reconciled into `provider` of
        {file}`~/.zcode/v2/config.json` as `custom:<name>` entries (upsert +
        GC of nixManaged entries; `builtin:*` slots and GUI-owned entries are
        never touched). Reconciled entries are fully nix-owned: GUI edits to
        them are reverted on next switch; delete the entry and recreate it in
        the GUI (without the `nixManaged` marker) to hand it over.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      (lib.concatLists (
        lib.mapAttrsToList (name: s: [
          {
            assertion = (s.command != null) != (s.url != null);
            message = "programs.zcode.mcp.servers.${name}: exactly one of `command` or `url` must be set.";
          }
          {
            assertion = s.command != null || (s.args == [ ] && s.env == { });
            message = "programs.zcode.mcp.servers.${name}: `args`/`env` are only valid for local servers (`command`).";
          }
          {
            assertion = s.url != null || s.headers == { };
            message = "programs.zcode.mcp.servers.${name}: `headers` is only valid for remote servers (`url`).";
          }
        ]) cfg.mcp.servers
      ))
      ++ (lib.optionals (lib.isPath cfg.skills) [
        {
          assertion = lib.pathIsDirectory cfg.skills;
          message = "`programs.zcode.skills` must be a directory when set to a path";
        }
      ])
      ++ (lib.optionals (lib.isPath cfg.agents) [
        {
          assertion = lib.pathIsDirectory cfg.agents;
          message = "`programs.zcode.agents` must be a directory when set to a path";
        }
      ])
      ++ (lib.optionals (lib.isPath cfg.commands) [
        {
          assertion = lib.pathIsDirectory cfg.commands;
          message = "`programs.zcode.commands` must be a directory when set to a path";
        }
      ]);

    home.packages = lib.mkIf (packageWithExtraPackages != null) [ packageWithExtraPackages ];

    # deep-link 回跳:OAuth 完成后浏览器以 zcode:// 回调。xdg-mime 对未声明
    # scheme 会兜底扫 desktop file 的 MimeType,但 Firefox 系浏览器不认隐式
    # 关联 —— 不写 mimeapps.list 就静默丢弃回调,浏览器显示"认证成功"而
    # zcode 永久等待(实测 2026-08-19)
    xdg.mimeApps.defaultApplications."x-scheme-handler/zcode" = "zcode.desktop";

    home.file =
      {
        ".zcode/AGENTS.md" =
          if (lib.isPath cfg.agentsMd || lib.isDerivation cfg.agentsMd) then { source = cfg.agentsMd; }
          else lib.mkIf (cfg.agentsMd != "") { text = cfg.agentsMd; };
      }
      # agents/commands 不走 home.file(zcode 拒收 symlink),见 syncZcodeAgents;
      # skills 是只读资源,symlink 实测正常,保持声明式链接
      // (lib.optionalAttrs (lib.isPath cfg.skills) {
        ".zcode/skills" = {
          source = cfg.skills;
          recursive = true;
        };
      })
      // (lib.concatMapAttrs linkSkill (
        if builtins.isAttrs cfg.skills then cfg.skills else { }
      ));

    # ── agents/commands 拷贝部署(加载器拒 symlink,必须普通文件)──
    # 所有权:cmp 对账,有差异才覆盖(GUI 编辑会被下次 switch 还原);sidecar
    # .nix-managed 记录 nix 部署过的文件名,仅 GC 名单内的文件 —— GUI 自建
    # (glm-test 之类)与用户文件永不触碰
    home.activation.syncZcodeAgents = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      _zcode_dir_sync() {
        local src="$1" dir="''${HOME}/.zcode/$2"
        mkdir -p "$dir"
        # 注意:local a=x b=$a 同语句内 $a 未生效(set -u 下报 unbound),拆两行
        local sidecar="$dir/.nix-managed"
        local new="$sidecar.tmp"
        : > "$new" || return 1
        local f name
        for f in "$src"/*.md; do
          [[ -e "$f" ]] || continue
          name="''${f##*/}"
          if [[ ! -f "$dir/$name" ]] || ! cmp -s "$f" "$dir/$name"; then
            cp "$f" "$dir/$name.part" && mv -T "$dir/$name.part" "$dir/$name"
          fi
          chmod 644 "$dir/$name"
          printf '%s\n' "$name" >> "$new"
        done
        if [[ -f "$sidecar" ]]; then
          while IFS= read -r old; do
            [[ -n "$old" ]] || continue
            grep -qxF "$old" "$new" || rm -f "$dir/$old"
          done < "$sidecar"
        fi
        mv -T "$new" "$sidecar"
      }
      _zcode_dir_sync ${agentsFarm} agents \
        || echo "WARNING: zcode agents 部署失败,下次 switch 重试"
      _zcode_dir_sync ${commandsFarm} commands \
        || echo "WARNING: zcode commands 部署失败,下次 switch 重试"
    '';

    # ── providers 对账:~/.zcode/v2/config.json ──
    home.activation.syncZcodeProviders = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      _zcode_providers_sync() {
        local cfg="''${HOME}/.zcode/v2/config.json"
        [[ -f "$cfg" ]] || { echo "zcode: v2/config.json 不存在(应用未首启),跳过 providers 注入"; return 0; }

        local work
        work=$(mktemp "$cfg.nixXXXXXX") || return 1
        cp "$cfg" "$work"

        # GC:nixManaged 但已不在 options 的条目整条回收
        # (注意 IN 写法:不能写 ($keep | index(.key)) —— pipe 上下文错位直接报错)
        ${jq} --argjson keep "$(${jq} -c 'map(.id)' ${providerManifest})" \
          '.provider |= ((. // {}) | with_entries(select((.value.nixManaged != true) or (.key | IN($keep[])))))' \
          "$work" > "$work.tmp" && mv "$work.tmp" "$work"

        local entry id sf key
        while IFS= read -r entry; do
          id=$(${jq} -r '.id' <<<"$entry")
          sf=$(${jq} -r '.secretFile' <<<"$entry")
          if [[ ! -r "$sf" ]]; then
            echo "WARNING: zcode: secret $sf 不可读,跳过 $id(sops 未激活?)"
            continue
          fi
          key=$(<"$sf")

          if ${jq} -e --arg id "$id" '.provider[$id]' "$work" >/dev/null 2>&1 \
            && ! ${jq} -e --arg id "$id" '(.provider[$id] // {}).nixManaged == true' "$work" >/dev/null; then
            : # 条目存在但无 nixManaged 标记 → GUI/用户所有,完全不动
          else
            # 不存在,或 nixManaged=true → 整条按 manifest 重写(nix 管辖即 nix 全权,
            # 漂移随 activation 自愈;GUI 改动会被 switch 还原,想自管就删条目重建)
            ${jq} --arg id "$id" --arg key "$key" --argjson tmpl "$(${jq} '.template' <<<"$entry")" \
              '.provider[$id] = ($tmpl + {
                 nixManaged: true,
                 options: ($tmpl.options + {apiKey: $key})
               })' "$work" > "$work.tmp" && mv "$work.tmp" "$work"
          fi
        done < <(${jq} -c '.[]' ${providerManifest})

        if ! cmp -s "$cfg" "$work"; then
          mv -T "$work" "$cfg"
        else
          rm -f "$work"
        fi
      }
      _zcode_providers_sync || echo "WARNING: zcode providers 注入失败,下次 switch 重试"
    '';

    # ── mcp 对账:~/.zcode/cli/config.json(与 providers 同 DAG 串行,同文件不同文件无冲突,
    #    但保持 providers→mcp 固定顺序便于日志阅读)──
    home.activation.syncZcodeMcp = lib.hm.dag.entryAfter [
      "writeBoundary"
      "syncZcodeProviders"
    ] ''
      _zcode_mcp_render_template() {
        # 循环替换模板 JSON 里所有 "@secret:<path>[:<prefix>]" 占位符为
        # prefix + secret 内容(整串精确匹配,jq --arg 传递,无注入面)
        local json="$1" ph rest path prefix val
        while [[ "$json" == *@secret:* ]]; do
          ph=$(grep -oE '@secret:[^"]*' <<<"$json" | head -n1)
          rest=''${ph#@secret:}
          if [[ "$rest" == *:* ]]; then
            path=''${rest%%:*}; prefix=''${rest#*:}
          else
            path="$rest"; prefix=""
          fi
          if [[ ! -r "$path" ]]; then
            echo "WARNING: zcode mcp: secret $path 不可读,跳过本条目"
            return 1
          fi
          val="$prefix$(<"$path")"
          json=$(${jq} --arg ph "$ph" --arg val "$val" \
            'walk(if . == $ph then $val else . end)' <<<"$json")
        done
        printf '%s' "$json"
      }

      _zcode_mcp_sync() {
        local cfg="''${HOME}/.zcode/cli/config.json"
        mkdir -p "$(dirname "$cfg")"
        [[ -f "$cfg" ]] || printf '{}' > "$cfg"

        local work
        work=$(mktemp "$cfg.nixmcpXXXXXX") || return 1
        cp "$cfg" "$work"

        # GC:nixManaged 但已不在 options 的条目回收(mcp.servers 可能不存在)
        ${jq} --argjson keep "$(${jq} -c 'map(.id)' ${mcpManifest})" \
          '.mcp = ((.mcp // {}) | .servers = ((.servers // {}) | with_entries(select((.value.nixManaged != true) or (.key | IN($keep[]))))))' \
          "$work" > "$work.tmp" && mv "$work.tmp" "$work"

        local entry id rendered
        while IFS= read -r entry; do
          id=$(${jq} -r '.id' <<<"$entry")
          rendered=$(_zcode_mcp_render_template "$(${jq} -c '.template' <<<"$entry")") || continue
          ${jq} --arg id "$id" --argjson def "$rendered" \
            '.mcp.servers[$id] = ($def + {nixManaged: true})' "$work" > "$work.tmp" && mv "$work.tmp" "$work"
        done < <(${jq} -c '.[]' ${mcpManifest})

        if ! cmp -s "$cfg" "$work"; then
          mv -T "$work" "$cfg"
          chmod 600 "$cfg"   # env/headers 含明文 secret,收紧(umask 兜底)
        else
          rm -f "$work"
        fi
      }
      _zcode_mcp_sync || echo "WARNING: zcode MCP 注入失败,下次 switch 重试"
    '';
  };
}
