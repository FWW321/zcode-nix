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
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          zcode = pkgs.callPackage ./pkgs/zcode { };
          default = self.packages.${system}.zcode;
        }
      );

      overlays.default = final: _prev: {
        zcode = final.callPackage ./pkgs/zcode { };
      };

      homeManagerModules = {
        zcode = import ./modules/zcode.nix;
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
          pkgs = nixpkgs.legacyPackages.${system};

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
                  # 测试 pkgs 无 zcode(overlay 归消费者挂),显式置空
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
        }
      );
    };
}
