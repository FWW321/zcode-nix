{
  description = "ZCode (Zhipu GLM official ADE) — nix packaging + Home Manager module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # 仅供 checks(activation 干跑/shellcheck 需要真实 HM 求值渲染 .data);
    # 消费者自带 HM,不构成约束
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, home-manager }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      # zcode 是闭源包(license: unfree),legacyPackages 的默认 config 在
      # eval 期即拒绝求值(2026-08-22 实测:packages output 令 flake check
      # 全红)。本 flake 的 packages/checks 需显式放行;消费者仍受自身
      # nixpkgs.config.allowUnfree 约束(与 nixpkgs unfree 包惯例一致)
      pkgsFor = system: import nixpkgs { inherit system; config.allowUnfree = true; };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          zcode = pkgs.callPackage ./pkgs/zcode { };
          default = self.packages.${system}.zcode;
        }
      );

      overlays.default = final: _prev: {
        zcode = final.callPackage ./pkgs/zcode { };
      };

      # 传路径而非 import 结果:模块系统记真实 _file → 消费者的 option 文档/
      # 报错定位指向本仓文件而非 <unknown-file>
      homeManagerModules = {
        zcode = ./modules/zcode.nix;
        default = self.homeManagerModules.zcode;
      };

      # ── checks:内嵌 activation 脚本与 skill 校验的防线 ──
      # 背景:模块把 bash 嵌进 Nix 字符串,没有编译器兜底;2026-08-20 交付过
      # `local a=x b=$a` 同语句引用坑(set -u 下 unbound,activation 静默失败)。
      # 两条防线:shellcheck 盯静态坑,干跑测试盯动态坑( flakes check 期暴露,
      # 不再等用户 switch 撞墙)。
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;

          # 真实 HM 求值:完整 option 合并 + DAG 渲染,夹具数据打满全部选项族
          hmConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.zcode
              {
                home.username = "tester";
                home.homeDirectory = "/home/tester";
                home.stateVersion = "26.05";
                programs.zcode = {
                  enable = true;
                  # 置空:不把 Electron 大包拉进 checks 闭包(自含默认已可
                  # 求值,但求值≠必装,夹具聚焦 activation 脚本本身)
                  package = null;
                  agents.robot = {
                    description = "dry-run fixture agent";
                    model = "custom:x:y";
                    prompt = "test body";
                  };
                  commands.hi = "say hi";
                  skills.fixture = ./tests/fixture-skill;
                  # toString 会丢 path context(secret 路径进不了闭包,沙箱
                  # 里不可读);"${./path}" 字符串插值保 context。仅夹具问题:
                  # 真实用法 apiKeyFile 是 /run/secrets 类运行时路径
                  providers.demo = {
                    kind = "anthropic";
                    baseURL = "https://example.test/v1";
                    apiKeyFile = "${./tests/fixture-apikey}";
                    models.m1 = {
                      context = 1000;
                      output = 100;
                    };
                  };
                  mcp.servers.echo = {
                    command = "echo-server";
                    args = [ "-x" ];
                    env.TOKEN.file = "${./tests/fixture-apikey}";
                  };
                };
              }
            ];
          };

          # .data 是渲染后的纯 bash(store 路径已内插),shellcheck/干跑都用它;
          # writeText 的字符串上下文连带 farm/manifest 依赖一起进闭包
          act = hmConfig.config.home.activation;
          render =
            name: pkgs.writeText "zcode-${name}-rendered" act.${name}.data;
        in
        {
          # 1) 静态:全部内嵌脚本 + 校验器 + 干跑测试本体过 shellcheck
          zcode-shellcheck = pkgs.runCommand "zcode-shellcheck" {
            nativeBuildInputs = [ pkgs.shellcheck ];
          } ''
            shellcheck -s bash \
              ${./modules/skill-frontmatter-check.sh} \
              ${./tests/activation-dryrun.sh} \
              ${render "syncZcodeAgents"} \
              ${render "syncZcodeProviders"} \
              ${render "syncZcodeMcp"}
            touch "$out"
          '';

          # 2) 动态:沙箱 HOME 打仿真 GUI 状态,断言拷贝/GC/零接触/幂等四条性质
          zcode-activation-dryrun = pkgs.runCommand "zcode-activation-dryrun" {
            nativeBuildInputs = [ pkgs.jq ];
          } ''
            bash ${./tests/activation-dryrun.sh} \
              ${render "syncZcodeAgents"} \
              ${render "syncZcodeProviders"} \
              ${render "syncZcodeMcp"} \
              ${./modules/skill-frontmatter-check.sh} \
              ${hmConfig.config.home.file.".zcode/skills/fixture".source}
            touch "$out"
          '';

          # 3) options 参考文档:34 个 option 的 description 真源自动渲染
          # (nixosOptionsDoc — HM 官方文档同款;警告即失败,description
          # 缺失会被 check 期拦下)。只收录本模块命名空间,HM 自身
          # option 树已有官方文档,不重复
          zcode-options-doc =
            let
              root = toString self.outPath;
              rel = p: nixpkgs.lib.removePrefix "${root}/" (toString p);
              # 声明位置 → GitHub 链接;非本仓声明 assert 拦下
              transformDeclaration =
                d:
                assert nixpkgs.lib.hasPrefix root (toString d);
                {
                  name = rel d;
                  url = "https://github.com/FWW321/zcode-nix/blob/main/${rel d}";
                };
              doc = pkgs.nixosOptionsDoc {
                documentType = "none";
                options.programs.zcode = hmConfig.options.programs.zcode;
                transformOptions = opt: opt // {
                  declarations = map transformDeclaration opt.declarations;
                };
              };
            in
            pkgs.runCommand "zcode-options-doc" { } ''
              install -Dm644 ${doc.optionsCommonMark} $out/options.md
              install -Dm644 ${doc.optionsJSON}/share/doc/nixos/options.json $out/options.json
            '';
        }
      );
    };
}
