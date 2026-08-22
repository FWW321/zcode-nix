# MCP 判别联合 assertions + 路径类断言(nix-unit)。
#
# 为什么只有这个域进 nix-unit:type 系统表达不了 command/url 互斥,
# assertion 是唯一防线;写反(如 != 手误)会让无效配置静默穿过 eval、
# 到 zcode 运行时才炸 —— 与本仓 checks 立意(失败提前到 check 期)相反。
# 正例投影 isDerivation(求值通过即产出),负例投影 activationPackage
# (Failed assertions 在其求值路径上 throw,深压之前触发)。
# activation 行为级(shellcheck/干跑)在 flake.nix checks
{ pkgs, home-manager }:

let
  base = {
    home.username = "tester";
    home.homeDirectory = "/home/tester";
    home.stateVersion = "26.05";
  };
  mkActivation =
    zcode:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        ../modules/zcode.nix
        base
        {
          programs.zcode = {
            enable = true;
            # 置空:Electron 大包不进求值闭包(与 flake.nix checks 夹具同款)
            package = null;
          }
          // zcode;
        }
      ];
    }).config.home.activationPackage;
in
{
  test-local-command-only-passes = {
    expr = pkgs.lib.isDerivation (mkActivation {
      mcp.servers.echo.command = "echo-server";
    });
    expected = true;
  };
  test-remote-url-only-passes = {
    expr = pkgs.lib.isDerivation (mkActivation {
      mcp.servers.remote.url = "https://mcp.example.com/mcp";
      mcp.servers.remote.headers.Authorization = "Bearer x";
    });
    expected = true;
  };
  test-command-and-url-rejected = {
    expr = mkActivation {
      mcp.servers.both.command = "x";
      mcp.servers.both.url = "https://y";
    };
    expectedError.type = "ThrownError";
    expectedError.msg = "exactly one of `command` or `url`";
  };
  test-neither-command-nor-url-rejected = {
    expr = mkActivation {
      mcp.servers.empty = { };
    };
    expectedError.type = "ThrownError";
    expectedError.msg = "exactly one of `command` or `url`";
  };
  test-args-on-remote-rejected = {
    expr = mkActivation {
      mcp.servers.remote.url = "https://y";
      mcp.servers.remote.args = [ "-x" ];
    };
    expectedError.type = "ThrownError";
    expectedError.msg = "`args`/`env` are only valid for local servers";
  };
  test-headers-on-local-rejected = {
    expr = mkActivation {
      mcp.servers.local.command = "x";
      mcp.servers.local.headers.X = "v";
    };
    expectedError.type = "ThrownError";
    expectedError.msg = "`headers` is only valid for remote servers";
  };
  test-skills-file-not-dir-rejected = {
    expr = mkActivation {
      skills = ../flake.nix;
    };
    expectedError.type = "ThrownError";
    expectedError.msg = "`programs.zcode.skills` must be a directory";
  };
}
