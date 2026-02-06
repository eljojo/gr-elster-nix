{
  description = "gr-elster - Elster smart meter receiver for GNU Radio";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Systems to support (includes Raspberry Pi)
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      # Helper to generate per-system outputs
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Package builder for each system
      mkPackages = system:
        let
          pkgs = import nixpkgs { inherit system; };
          python = pkgs.python3;

          # Core gr-elster library
          gr-elster = pkgs.stdenv.mkDerivation rec {
            pname = "gr-elster";
            version = "git";

            src = pkgs.fetchFromGitHub {
              owner = "argilo";
              repo = "gr-elster";
              rev = "master";
              sha256 = "sha256-jyjSMARDx3Ly+90kggmxJVHSp0FU0Ak2Tudv8ulJiLk";
            };

            nativeBuildInputs = [
              pkgs.cmake
              pkgs.pkg-config
              pkgs.swig
            ];

            buildInputs = [
              pkgs.gnuradio
              pkgs.volk
              pkgs.spdlog
              pkgs.gmp
              pkgs.boost
              python
              python.pkgs.numpy
              python.pkgs.pybind11
            ];

            cmakeFlags = [
              "-DCMAKE_BUILD_TYPE=Release"
              "-DGR_ELSTER_ENABLE=ON"
            ];

            postInstall = ''
              mkdir -p $out/share/gnuradio/grc/blocks
              cp $src/apps/*.grc $out/share/gnuradio/grc/blocks/

              mkdir -p $out/bin
              cp $src/apps/decode_pcap.py $out/bin/elster-decode
              chmod +x $out/bin/elster-decode
            '';
          };

          # Find the correct soapy modules path (varies by system)
          soapyModulesPath = if pkgs.stdenv.isDarwin
            then "${pkgs.soapyrtlsdr}/lib/SoapySDR/modules0.8-3"
            else "${pkgs.soapyrtlsdr}/lib/SoapySDR/modules0.8";

          # Generate the nogui Python script from our custom GRC (uses Soapy, not osmosdr)
          elster-nogui-py = pkgs.runCommand "elster-nogui-py" {
            nativeBuildInputs = [ pkgs.gnuradio ];
            HOME = "/tmp";
          } ''
            mkdir -p $out /tmp/.grc_gnuradio

            # Generate the hierarchical block first and put it where grcc can find it
            export GRC_HIER_PATH=$out
            export GRC_BLOCKS_PATH="$out:${gr-elster}/share/gnuradio/grc/blocks"

            grcc -o $out ${gr-elster}/share/gnuradio/grc/blocks/elster_channel_rx.grc

            # Now generate our custom nogui script (uses Soapy source, works on all platforms)
            grcc -o $out ${./grc/elster_nogui.grc}
          '';

          # Complete receiver package with wrapper script
          elster-rx = pkgs.writeShellScriptBin "elster-rx" ''
            set -e

            # Environment setup
            export SOAPY_SDR_PLUGIN_PATH="${soapyModulesPath}"
            export PYTHONPATH="${elster-nogui-py}:${gr-elster}/lib/${python.libPrefix}/site-packages:${pkgs.gnuradio}/lib/${python.libPrefix}/site-packages:${python.pkgs.numpy}/${python.sitePackages}:''${PYTHONPATH:-}"
            export GRC_BLOCKS_PATH="${gr-elster}/share/gnuradio/grc/blocks"

            # Data directory for pcap files
            DATA_DIR="''${ELSTER_DATA_DIR:-$PWD}"
            cd "$DATA_DIR"

            # Use local script if present, otherwise use the built-in one
            if [ -f "./elster_nogui.py" ]; then
              exec ${python}/bin/python3 ./elster_nogui.py "$@"
            else
              exec ${python}/bin/python3 ${elster-nogui-py}/elster_nogui.py "$@"
            fi
          '';

          # Decoder utility
          elster-decode = pkgs.writeShellScriptBin "elster-decode" ''
            export PYTHONPATH="${python.pkgs.pygraphviz}/lib/${python.libPrefix}/site-packages:''${PYTHONPATH:-}"
            exec ${python}/bin/python3 ${gr-elster}/bin/elster-decode "$@"
          '';

        in {
          inherit gr-elster elster-rx elster-decode elster-nogui-py;
          default = gr-elster;
        };

    in {
      # Per-system outputs
      packages = forAllSystems (system: mkPackages system);

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${(mkPackages system).elster-rx}/bin/elster-rx";
        };
        elster-rx = {
          type = "app";
          program = "${(mkPackages system).elster-rx}/bin/elster-rx";
        };
        elster-decode = {
          type = "app";
          program = "${(mkPackages system).elster-decode}/bin/elster-decode";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          python = pkgs.python3;
          packages = mkPackages system;
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.gnuradio
              pkgs.rtl-sdr
              pkgs.soapysdr
              pkgs.soapyrtlsdr
              python
              python.pkgs.numpy
              python.pkgs.pygraphviz
              packages.gr-elster
              packages.elster-rx
              packages.elster-decode
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.gqrx
            ];

            shellHook = ''
              export SOAPY_SDR_PLUGIN_PATH="$(ls -d ${pkgs.soapyrtlsdr}/lib/SoapySDR/modules* | head -1)"
              export GRC_BLOCKS_PATH="${packages.gr-elster}/share/gnuradio/grc/blocks''${GRC_BLOCKS_PATH:+:$GRC_BLOCKS_PATH}"
              export PYTHONPATH="${packages.gr-elster}/lib/${python.libPrefix}/site-packages:''${PYTHONPATH:-}"

              echo ""
              echo "=== gr-elster dev shell ==="
              echo ""
              echo "Commands:"
              echo "  elster-rx                    - Run CLI receiver"
              echo "  elster-decode *.pcap         - Decode captured packets"
              echo "  gnuradio-companion           - Open GUI (Linux)"
              echo ""
            '';
          };
        });

      # NixOS module for systemd service
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.elster;
          packages = mkPackages pkgs.system;
        in {
          options.services.elster = {
            enable = lib.mkEnableOption "Elster smart meter receiver";

            dataDir = lib.mkOption {
              type = lib.types.path;
              default = "/var/lib/elster";
              description = "Directory to store pcap captures";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "elster";
              description = "User to run the service as";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "elster";
              description = "Group to run the service as";
            };

            frequency = lib.mkOption {
              type = lib.types.int;
              default = 910600000;
              description = "Center frequency in Hz (default 910.6 MHz)";
            };

            gain = lib.mkOption {
              type = lib.types.int;
              default = 30;
              description = "RF gain in dB";
            };

            deviceSerial = lib.mkOption {
              type = lib.types.str;
              default = "";
              example = "elster";
              description = "RTL-SDR serial number to use (set with rtl_eeprom -s). Empty = use first available.";
            };
};

          config = lib.mkIf cfg.enable {
            # Create user/group
            users.users.${cfg.user} = {
              isSystemUser = true;
              group = cfg.group;
              home = cfg.dataDir;
              extraGroups = [ "plugdev" ];  # For USB access to RTL-SDR
            };
            users.groups.${cfg.group} = {};

            # Ensure data directory exists
            systemd.tmpfiles.rules = [
              "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.group} -"
            ];

            # udev rules for RTL-SDR
            services.udev.extraRules = ''
              SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", GROUP="plugdev", MODE="0666"
              SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", GROUP="plugdev", MODE="0666"
            '';

            # The systemd service
            systemd.services.elster = {
              description = "Elster Smart Meter Receiver";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];

              environment = {
                ELSTER_DATA_DIR = cfg.dataDir;
                ELSTER_DEV_ARGS = lib.optionalString (cfg.deviceSerial != "") "serial=${cfg.deviceSerial}";
                SOAPY_SDR_PLUGIN_PATH = "${pkgs.soapyrtlsdr}/lib/SoapySDR/modules0.8";
                PYTHONPATH = lib.concatStringsSep ":" [
                  "${packages.gr-elster}/lib/${pkgs.python3.libPrefix}/site-packages"
                  "${pkgs.gnuradio}/lib/${pkgs.python3.libPrefix}/site-packages"
                  "${pkgs.python3.pkgs.numpy}/${pkgs.python3.sitePackages}"
                  "${packages.elster-nogui-py}"
                ];
                GRC_BLOCKS_PATH = "${packages.gr-elster}/share/gnuradio/grc/blocks";
              };

              serviceConfig = {
                Type = "simple";
                User = cfg.user;
                Group = cfg.group;
                WorkingDirectory = cfg.dataDir;
                ExecStart = "${packages.elster-rx}/bin/elster-rx";
                Restart = "always";
                RestartSec = 10;

                # Hardening
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                ReadWritePaths = [ cfg.dataDir ];
                PrivateTmp = true;
              };
            };

            # Timer-based decode service (runs hourly)
            systemd.services.elster-decode = {
              description = "Decode Elster pcap files";
              after = [ "elster.service" ];

              environment = {
                PYTHONPATH = "${pkgs.python3.pkgs.pygraphviz}/lib/${pkgs.python3.libPrefix}/site-packages";
              };

              serviceConfig = {
                Type = "oneshot";
                User = cfg.user;
                Group = cfg.group;
                WorkingDirectory = cfg.dataDir;
                ExecStart = "${pkgs.writeShellScript "elster-decode-all" ''
                  cd ${cfg.dataDir}
                  ${packages.elster-decode}/bin/elster-decode *.pcap > decoded-$(date +%Y%m%d-%H%M%S).txt 2>&1 || true
                ''}";
              };
            };

            systemd.timers.elster-decode = {
              description = "Hourly Elster packet decode";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = "hourly";
                Persistent = true;
              };
            };
          };
        };

      # Overlay for use in other flakes
      overlays.default = final: prev: {
        gr-elster = (mkPackages prev.system).gr-elster;
        elster-rx = (mkPackages prev.system).elster-rx;
        elster-decode = (mkPackages prev.system).elster-decode;
      };
    };
}
