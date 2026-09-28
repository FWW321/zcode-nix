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
#   opencode.json 是纯声明式文件,上游模块可拥有整个文件;zcode 的 provider
#   真源 v2/provider_config.json 与 cli/config.json 是 GUI 活跃写区,整文件
#   声明式会与 GUI 拉锯 → 对账注入(upsert 只管 nix 管辖条目):
#     - provider 注入 providerRules/providerOrder/providerModelRules
#       (sidecar 记名,见 syncZcodeProviders);v2/config.json 的 provider
#       区是 legacy 死信层,旧方案的 nixManaged 条目随 switch 回收
#     - mcp 写入 cli/config.json 的 mcp.servers(见下)
#     - builtin:* 槽位绝不碰(oauth 派生 token 的领地,实测 2026-08-19)
#     - 条目存在但未被 sidecar/nixManaged 记名 → GUI/用户所有,零接触
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
# key 轮换陷阱(2026-09-28 实测):apiKeyFile 是常量路径,单换 key 不改
# HM generation → providers sync 不重跑,provider_config.json 停留旧 key
# ("switch 一次不够")。providers.<name>.apiKeySource(密文源 path)的
# sha256 作非敏感指纹进 manifest:轮换 → generation 变 →
# home-manager-<user>.service 确定性重启重跑 sync,不再依赖 sops 物化
# 与 activation 的先后(明文 key 仍绝不进 store)。
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

  # kind(模块词汇,按请求路径) → 上游 ModelProviderApiFormat
  # (legacyModelProviderSerialized.ts resolveModelProviderApiFormat 的枚举)
  apiTypeOfKind = {
    anthropic = "anthropic-messages";
    "openai-compatible" = "openai-chat-completions";
    openai = "openai-responses";
  };

  # ── providers:选项 → v2/provider_config.json 对账 manifest ──
  # 目标文件勘误(2026-09-22,开源源码实证):v2/config.json 的 provider 区是
  # legacy 死信层——personal-provider-config-repository.ts #readLocked 仅在
  # provider_config.json 不存在时跑一次性 importLegacy,此后 config.json
  # 永不再读。GUI 面板/agent 注册表的真源是 provider_config.json:
  #   - providerConfigRules.providerRules(显示条件 group=="standard-personal")
  #   - providerOrder(appendCurrentProviderOrder 语义:去重后 append 末尾)
#   - modelConfigRules.providerModelRules(与迁移器 setExact 同层;
#     properties.{contextWindow,inputFormat} + optionSpecs.{reasoningLevel,
#     maxOutputTokens})
  # 注入形状对齐 createPersonalProviderConfig(legacy 迁移器)。
  # 历史遗留条目(迁移器从旧 config.json 导出的)与注入同键无缝接管:
  # 无 sidecar 记录 → GC 零接触;同 providerId → upsert 收编
  providerManifest = pkgs.writeText "zcode-provider-manifest.json" (builtins.toJSON (
    lib.mapAttrsToList (name: p: {
      id = "custom:${name}";
      secretFile = p.apiKeyFile;
      # apiKey 由 activation 渲染注入 access,不进 store
      # keyFingerprint:apiKeySource(密文源)的 sha256,非敏感,但让
      # manifest 从而 HM generation 随 key 轮换确定性变化,service 必重启
      # 重跑 sync;空串 = 未声明指纹,行为与之前一致
      keyFingerprint = lib.optionalString (p.apiKeySource != null)
        (builtins.hashFile "sha256" p.apiKeySource);
      providerRule = {
        providerId = "custom:${name}";
        providerName = name;
        config = {
          group = "standard-personal";
          access.type = "api-key";
          api = {
            type = apiTypeOfKind.${p.kind};
            baseUrl = p.baseURL;
          };
          personalModelIds = lib.attrNames p.models;
          modelOrder = lib.attrNames p.models;
        };
      };
      modelRules = lib.mapAttrsToList (mid: m:
        let
          # sparse 语义:inputFormat 未设的模态键不写 —— 上游
          # modelInputFormatDataSchema 允许省键,省略即沿用该模态默认
          fmt = lib.optionalAttrs (m.inputFormat != null)
            (lib.filterAttrs (_: v: v != null) m.inputFormat);
        in {
          providerId = "custom:${name}";
          modelId = mid;
          config = {
            # 注意 // 是浅合并:fmt 与 contextWindow 都在 properties 平层拼;
            # reasoning 分支同理必须在 optionSpecs 层拼,放到 config 层会
            # 整个顶掉 optionSpecs
            properties = { contextWindow = m.context; }
              // (lib.optionalAttrs (fmt != { }) { inputFormat = fmt; });
            optionSpecs = {
              maxOutputTokens.max = m.output;
            } // (lib.optionalAttrs (m.reasoning != null) {
              # values 供 resolveRegistryThoughtLevel 校验档名;map 是 wire 翻译
              # 表达式(compileModelOptionMaps)——缺任一 thoughtLevel 即被静默吞
              reasoningLevel = {
                inherit (m.reasoning) map;
                values = m.reasoning.levels;
              };
            });
          };
        }
      ) p.models;
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
  # (programs.opencode 上游 normalizeSkill 同款 + frontmatter 校验)
  # cp 而非 ln:源可能是 /home 下的本地路径,store 里放 symlink 会悬空。
  # 坑:脚本里 toString 会丢纯 path 的依赖 context(闭包里没有源路径,沙箱
  # 里 -d/-f 双 false)—— 源经 env 传入(自动入闭包),脚本读 env 值
  normalizeSkillSource =
    source:
    pkgs.runCommandLocal "zcode-skill" { skillSource = source; } ''
      source=$skillSource
      if [[ -d "$source" ]]; then
        bash ${./skill-frontmatter-check.sh} "$source/SKILL.md"
        mkdir -p "$out"
        cp -a "$source"/. "$out"/
      elif [[ -f "$source" ]]; then
        bash ${./skill-frontmatter-check.sh} "$source"
        mkdir "$out"
        cp "$source" "$out/SKILL.md"
      else
        echo "zcode skill source must be a file or directory: $source" >&2
        exit 1
      fi
    '';

  # 技能三态 → home.file 条目(内联文本 | 单文件 | 目录)。
  # 文件/目录一律经 normalizeSkillSource:挂 frontmatter 校验 + 入 store;
  # 内联文本是配置里手写的,所见即所得,不校验
  linkSkill =
    name: content:
    if (lib.isPath content && lib.pathIsDirectory content)
      || (lib.isString content && lib.hm.strings.isPathLike content) then
      { ".zcode/skills/${name}" = { source = normalizeSkillSource content; recursive = true; }; }
    else if lib.isPath content then
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
      # 没有这份元数据,agents 的 thoughtLevel 会被 resolveRegistryThoughtLevel
      # 静默吞掉(开源源码实证);上游 catalog 对 MiniMax 等第三方模型普遍
      # reasoning: null,自定义 provider 想用思考档只能自己声明
      reasoning = lib.mkOption {
        type = lib.types.nullOr providerReasoningModule;
        default = null;
        description = ''
          Thinking-level metadata for this model. Without it
          {option}`programs.zcode.agents.<name>.thoughtLevel` is silently
          ignored for custom models. Injected into both the GUI-side
          (`v2/config.json` `reasoning.variants`) and the agent-side
          (`v2/provider_config.json` `optionSpecs.reasoningLevel`).
        '';
      };
      # 模态落点:上游 wire schema completeModelInputFormatDataSchema 五键
      # 全 bool(supportsText/Image/Video/Audio/Pdf),规则层 sparse 允许省键;
      # 本模块只开多模态三开关,text/pdf 沿用上游默认。运行时闸门是
      # projectMessagesForInputFormat:不支持的模态块被替换成占位文本,
      # 静默降级 —— 声明错了不会报错,只是输入悄悄变残
      inputFormat = lib.mkOption {
        type = lib.types.nullOr inputFormatModule;
        default = null;
        description = ''
          Input-modality flags, rendered into `properties.inputFormat`
          (schema-verified: upstream accepts five boolean keys
          `supportsText`/`supportsImage`/`supportsVideo`/`supportsAudio`/
          `supportsPdf` with per-key omission; this option exposes the three
          modality switches, unset keys are simply not written). This is
          the runtime gate for multimodal input: media blocks of an
          unsupported kind are projected out of the request as placeholder
          text, so e.g. video input to a model without `supportsVideo`
          silently degrades instead of erroring.
        '';
      };
    };
  };

  providerReasoningModule = lib.types.submodule {
    options = {
      levels = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        description = ''
          Level names accepted by this model (e.g. `["low" "high" "max"]`).
          Order matters: the last entry is the default level
          (source-verified: `defaultLevel = values.at(-1)`).
        '';
      };
      map = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = ''
          Wire-translation expression: evaluated with `reasoningLevel` bound
          to the chosen level, producing the request-body patch. Catalog
          examples (pick per endpoint dialect):
            GLM anthropic   : `{ "thinking": { "type": "adaptive" }, "output_config": { "effort": reasoningLevel } }`
            OpenAI          : `{ "reasoning_effort": reasoningLevel }`
            OpenRouter      : `{ "reasoning": { "effort": reasoningLevel } }`
            boolean toggles : `{ "enable_thinking": reasoningLevel != "disabled" }`

          Level-name coupling: when the expression branches on level names
          (e.g. `if reasoningLevel == "high"`), those names must use exactly
          the vocabulary of `levels` — the chosen level string is bound
          verbatim, so a mismatched naming scheme never matches and the
          patch silently never applies (field-verified 2026-09-28).
        '';
      };
    };
  };

  inputFormatModule = lib.types.submodule {
    options = {
      supportsImage = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Accept image inputs (`null` = key omitted, upstream default applies).";
      };
      supportsVideo = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Accept video inputs (Read-tool video branch, `video_url` wire format).";
      };
      supportsAudio = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Accept audio inputs.";
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
      apiKeySource = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Eval-time source of the key material, as a path. MUST be
          ciphertext (e.g. the sops/age-encrypted file that produces
          {option}`apiKeyFile`) — never a plaintext key: path values are
          copied into the store.

          Its sha256 is embedded in the provider manifest as a
          non-sensitive fingerprint, so rotating the key changes the
          manifest, the Home Manager generation and thus
          `home-manager-<user>.service`, which deterministically re-runs
          the provider sync against the freshly materialized key (NixOS
          switches run activation scripts — sops materialization — before
          restarting changed units). Without it `apiKeyFile` is a constant
          runtime path: key rotation leaves the generation byte-identical,
          so nothing re-renders `provider_config.json` until an unrelated
          config change does — the "switch twice" trap.

          Granularity is the whole file: rotating other secrets in the
          same sops file only costs one extra idempotent sync.
        '';
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
  # bool 必须显式 true/false:Nix 的 toString false="" / true="1"(shell 语义),
  # 直排会把 false 渲染成 YAML null(= 客户端默认值,配置静默蒸发)、
  # true 渲染成整数 1(schema 未必收)——injectAgentsMd 实测踩中
  yamlScalar =
    v:
    if lib.isBool v then (if v then "true" else "false")
    else if lib.isInt v || lib.isFloat v then toString v
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
          "permissionMode"
          "memory"
          "tools"
          "disallowedTools"
          "skills"
          "background"
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
          `custom:custom%3Amy-provider:My-Model` (NOT the `<provider>/<model>`
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
        Thinking effort. Two preconditions, both source-verified:
        (1) only effective with an explicit `model`; (2) that model must
        carry thinking-level metadata — catalog builtin models
        (e.g. GLM via the OAuth slot) have it, but custom-provider models
        do not unless `providers.<name>.models.<m>.reasoning` is set,
        otherwise the level is silently dropped. Kept a free string on
        purpose: the set of valid levels is model-dependent (GLM:
        low/high/max/nothink; GPT: low/medium/high/xhigh; DeepSeek V4:
        high/max) — an enum here would wrongly reject valid combinations.
      '';
    };
    # 以下四项为 3.14.0 frontmatter schema 字段(开源源码 profile.ts:171-223 实证)
    permissionMode = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "auto" "plan" ]);
      default = null;
      description = ''
        Child-session permission mode. Only `auto` and `plan` are accepted
        from agent markdown — upstream deliberately blocks `bypass`/`yolo`
        escalation from repository-owned (project-level) definitions
        (VALID_PERMISSION_MODES in core/src/subagent/profile.ts); this module
        deploys user-level files only, which is the tier upstream trusts.
      '';
    };
    memory = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "user" "project" "local" ]);
      default = null;
      description = ''
        Persistent-memory scope for this subagent. Invalid values are
        ignored by zcode (agent still loads, memory disabled) — here it is
        a build-time enum instead, matching VALID_MEMORY_SCOPES.
      '';
    };
    skills = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        Skill names this subagent may use (exact match against the skill
        registry). `null` inherits all available skills.
      '';
    };
    background = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether this subagent runs in the background.";
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

    # 自含默认:消费方 pkgs 直接 callPackage 本仓库表达式,import 模块即用,
    # 不依赖(也不要求)本 flake 的 overlay;overlay 仍提供 pkgs.zcode 但仅为
    # 可选糖。null = 只出配置不装包
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.callPackage ../pkgs/zcode { };
      defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/zcode { }";
      description = "ZCode package. Defaults to building the in-repo expression with the consuming package set; set to null to manage installation yourself.";
    };

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
        `custom:custom%3Amy-provider:My-Model`. Keep filename and frontmatter
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
        Custom model providers reconciled into
        {file}`~/.zcode/v2/provider_config.json` — the live registry read by
        both the GUI and the agent (the old `v2/config.json` provider section
        is a legacy dead letter, only imported once when this file is absent).
        Per provider: a `standard-personal` provider rule (+ providerOrder
        registration) and per-model rules (context window, output cap,
        optional thinking levels). Sidecar-named entries are fully nix-owned:
        GUI edits revert on next switch (the GUI `enabled`/disabled flag is
        preserved); remove the provider from nix to reclaim it, or keep a
        GUI-created copy untouched by giving it another id. `builtin:*` and
        GUI-created rules are never touched.
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

    # ── 自写 desktop 文件死链清理(2026-08-26 实测踩坑)──
    # app 启动时把 wrapper 的 store 绝对路径写进
    # ~/.local/share/applications/zcode.desktop(APPIMAGE 注入,优先取 env);
    # 该目录优先级高于 profile,会遮蔽包里版本无关的 Exec=zcode 入口。
    # 版本升级 + 旧 store path GC 后,菜单点击执行死路径 → 静默无反应,
    # 而 app 只有成功启动一次才会重写该文件 —— 鸡生蛋。
    # 3.14.1 起 app 经 wrapper 启动即自清理(深链注册探测到系统级条目,
    # 见 pkgs/zcode/default.nix postFixup 注释),本段降级为兜底:覆盖
    # 3.14.1 之前写下的遗留条目、以及绕过 wrapper 裸跑 app 产生的条目。
    # 防线:activation 时 Exec 指向的 /nix/store 路径已不存在 → 删文件,
    # 让 profile 的入口接管;路径活着(app 正常自管)→ 零接触
    home.activation.pruneZcodeDeepLink = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      _zcode_desktop="''${XDG_DATA_HOME:-''${HOME}/.local/share}/applications/zcode.desktop"
      if [[ -f "$_zcode_desktop" ]]; then
        _zcode_exec=$(sed -n 's|^Exec="\(/nix/store/[^"]*\)".*|\1|p' "$_zcode_desktop")
        if [[ -n "$_zcode_exec" && ! -e "$_zcode_exec" ]]; then
          rm -f "$_zcode_desktop"
          echo "zcode: removed stale self-registered desktop entry (dead Exec: $_zcode_exec)"
        fi
      fi
    '';

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

    # ── providers 对账:~/.zcode/v2/provider_config.json(GUI/agent 共同真源)──
    home.activation.syncZcodeProviders = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # 所有权:文件 schema strict 塞不了 nixManaged 标记 → sidecar
      # (provider_config.nix-managed)记名:"P <providerId>" 为 provider 条目,
      # "M <pid>|<mid>" 为模型规则(旧格式裸行按 M 处理)。sidecar 未记名的
      # 条目(GUI 自建/legacy 迁移器产物)GC 零接触;同键则 upsert 收编:
      # nix 管辖即 nix 全权,GUI 改动随 switch 还原,provider 级 enabled
      # (GUI 停用意图)例外保留。
      _zcode_providers_sync() {
        local pc="''${HOME}/.zcode/v2/provider_config.json"
        [[ -f "$pc" ]] || { echo "zcode: v2/provider_config.json 不存在(应用未首启),跳过 providers 注入"; return 0; }

        local work
        work=$(mktemp "$pc.nixpcXXXXXX") || return 1
        cp "$pc" "$work"

        local sidecar="''${pc%.*}.nix-managed"
        local new="$sidecar.tmp"
        : > "$new" || return 1

        # 当前名单先行落盘(GC 的 keep 集合)
        local entry pid sf mid
        while IFS= read -r entry; do
          pid=$(${jq} -r '.id' <<<"$entry")
          printf 'P %s\n' "$pid" >> "$new"
          while IFS= read -r mid; do
            printf 'M %s|%s\n' "$pid" "$mid" >> "$new"
          done < <(${jq} -r '.modelRules[].modelId' <<<"$entry")
        done < <(${jq} -c '.[]' ${providerManifest})

        # GC:sidecar 记名但已不在 options → provider 条目连 order 摘除,
        # 模型规则整条回收(upsert 是整条重写,规则内容即 nix 声明)
        local line
        if [[ -f "$sidecar" ]]; then
          while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if [[ "$line" == "P "* ]]; then
              pid="''${line#P }"
              grep -qxF "P $pid" "$new" && continue
              ${jq} --arg pid "$pid" '
                .config.providerConfigRules.providerRules |= map(select(.providerId != $pid))
                | .config.providerOrder |= ((. // []) | map(select(. != $pid)))' \
                "$work" > "$work.tmp" && mv "$work.tmp" "$work"
            else
              pid="''${line#M }"; mid="''${pid#*|}"; pid="''${pid%%|*}"
              grep -qxF "M $pid|$mid" "$new" && continue
              ${jq} --arg pid "$pid" --arg mid "$mid" '
                .config.modelConfigRules.providerModelRules |=
                  map(select(.providerId != $pid or .modelId != $mid))' \
                "$work" > "$work.tmp" && mv "$work.tmp" "$work"
            fi
          done < "$sidecar"
        fi

        # upsert:providerRule(apiKey 由 secret 渲染)+ order append(去重后
        # 末尾,appendCurrentProviderOrder 语义)+ 模型规则整条。
        # 纳管条目在文件中缺失(GUI 删/改名过)→ 告警:已重建,指明正确路径
        # (防 GUI 侧改出幽灵重复,2026-09-28 M3.1 事故)
        local key
        while IFS= read -r entry; do
          pid=$(${jq} -r '.id' <<<"$entry")
          sf=$(${jq} -r '.secretFile' <<<"$entry")
          if [[ ! -r "$sf" ]]; then
            echo "WARNING: zcode: secret $sf 不可读,跳过 $pid(sops 未激活?)"
            continue
          fi
          key=$(<"$sf")

          if ! ${jq} -e --arg pid "$pid" \
            'any(.config.providerConfigRules.providerRules[]?; .providerId == $pid)' \
            "$work" >/dev/null 2>&1; then
            echo "WARNING: zcode: $pid 在文件中缺失(GUI 删/改名过?),已重建;换模型请改 nix 声明"
          fi

          ${jq} --arg pid "$pid" --arg key "$key" --argjson rule "$(${jq} '.providerRule' <<<"$entry")" '
            ($rule | .config.access.apiKey = $key) as $full
            | .config.providerConfigRules.providerRules |= (
                if any(.[]?; .providerId == $pid) then
                  map(if .providerId == $pid
                      then ((if has("enabled") then {enabled: .enabled} else {} end) + $full)
                      else . end)
                else . + [$full] end)
            | .config.providerOrder |= ((. // []) | map(select(. != $pid)) + [$pid])' \
            "$work" > "$work.tmp" && mv "$work.tmp" "$work"

          while IFS= read -r mrule; do
            mid=$(${jq} -r '.modelId' <<<"$mrule")
            if ! ${jq} -e --arg pid "$pid" --arg mid "$mid" \
              'any(.config.modelConfigRules.providerModelRules[]?; .providerId == $pid and .modelId == $mid)' \
              "$work" >/dev/null 2>&1; then
              echo "WARNING: zcode: 模型规则 $pid|$mid 在文件中缺失(GUI 删/改名过?),已重建;换模型请改 nix 声明"
            fi
            ${jq} --argjson rule "$mrule" '
              ($rule.providerId) as $pid | ($rule.modelId) as $mid
              | .config.modelConfigRules.providerModelRules |= (
                  if any(.[]?; .providerId == $pid and .modelId == $mid) then
                    map(if .providerId == $pid and .modelId == $mid then $rule else . end)
                  else . + [$rule] end)' \
              "$work" > "$work.tmp" && mv "$work.tmp" "$work"
          done < <(${jq} -c '.modelRules[]' <<<"$entry")
        done < <(${jq} -c '.[]' ${providerManifest})

        # 残留探测:同 provider 下未纳管、与纳管 modelId 大小写归一后同形的
        # 规则(GUI 改名逃逸出 upsert 的产物)。宁漏勿误报:仅精确同形(忽略
        # 大小写)才告警,条目本身零接触
        local rpid rmid ours
        while IFS=$'\t' read -r rpid rmid; do
          grep -qxF "M $rpid|$rmid" "$new" && continue
          while IFS= read -r ours; do
            if [[ "''${ours,,}" == "''${rmid,,}" ]]; then
              echo "WARNING: zcode: $rpid 下未纳管模型规则 \"$rmid\" 与纳管 \"$ours\" 仅大小写不同(疑似 GUI 改名残留),零接触;如需收敛请在 GUI 删除或改 nix 声明"
              break
            fi
          done < <(grep -F "M $rpid|" "$new" | cut -d'|' -f2-)
        done < <(${jq} -r '.config.modelConfigRules.providerModelRules[]? | [.providerId, .modelId] | @tsv' "$work")

        if ! cmp -s "$pc" "$work"; then
          mv -T "$work" "$pc"
        else
          rm -f "$work"
        fi

        # 死信层清尾:回收旧方案写进 config.json 的 nixManaged provider 条目
        # (legacy 一次性迁移后该层不再被读;仅在本次注入成功后执行,
        # GUI/builtin 条目零接触)
        local cfg="''${HOME}/.zcode/v2/config.json"
        if [[ -f "$cfg" ]]; then
          local cwork
          cwork=$(mktemp "$cfg.nixlgXXXXXX") || return 1
          if ${jq} '.provider |= ((. // {}) | with_entries(select(.value.nixManaged != true)))' \
            "$cfg" > "$cwork"; then
            if ! cmp -s "$cfg" "$cwork"; then mv -T "$cwork" "$cfg"; else rm -f "$cwork"; fi
          else
            rm -f "$cwork"
          fi
        fi

        mv -T "$new" "$sidecar"
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
