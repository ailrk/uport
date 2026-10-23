{ config, lib, pkgs, ... }:

let
  cfg = config.services.uport;
in {
  options.services.uport = {
    enable = lib.mkEnableOption "uport secure file upload/receive portal server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.uport-server;
      description = "The uport-server package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9822;
      description = "Port on which the uport server listens.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:9822";
      description = "Public base URL of the server (used to generate portal links).";
    };

    storagePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/uport";
      description = "Directory where uploaded files are stored.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.uport = {
      description = "uport file upload/receive portal server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        StateDirectory = "uport";
        ExecStart = "${cfg.package}/bin/uport-server";
        Environment = [
          "PORT=${toString cfg.port}"
          "BASE_URL=${cfg.baseUrl}"
          "UPLOAD_DIR=${cfg.storagePath}"
        ];
        Restart = "on-failure";
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.storagePath ];
      };
    };
  };
}
