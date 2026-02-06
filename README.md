# gr-elster-nix

Nix flake for receiving and decoding Elster smart meter data using an RTL-SDR dongle.

This is a Nix packaging of [gr-elster](https://github.com/argilo/gr-elster) by Clayton Smith (argilo), a GNU Radio out-of-tree module for receiving packets from Elster R2S smart meters on the 902-928 MHz ISM band. The meters form a mesh network and broadcast usage data every six hours.

## Requirements

- [Nix](https://nixos.org/) with flakes enabled
- An RTL-SDR dongle (RTL2832U-based)

## Quick start

Plug in your RTL-SDR and run the receiver:

```bash
nix run github:eljojo/gr-elster-nix
```

Packets are captured to `elster-NNN.pcap` files in the current directory. Decode them with:

```bash
nix run github:eljojo/gr-elster-nix#elster-decode -- *.pcap
```

## Dev shell

For development with GNU Radio Companion and other tools:

```bash
nix develop
```

This gives you `elster-rx`, `elster-decode`, `gnuradio-companion` (Linux), and all the SDR tooling.

## NixOS module (Raspberry Pi / headless server)

This flake includes a NixOS module that runs the receiver as a systemd service. Add it to your NixOS configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gr-elster.url = "github:eljojo/gr-elster-nix";
  };

  outputs = { nixpkgs, gr-elster, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux"; # or x86_64-linux
      modules = [
        gr-elster.nixosModules.default
        {
          services.elster = {
            enable = true;
            # dataDir = "/var/lib/elster";   # where pcap files are stored
            # gain = 30;                     # RF gain in dB
            # deviceSerial = "elster";       # RTL-SDR serial (see below)
          };
        }
      ];
    };
  };
}
```

The module sets up:

- A dedicated `elster` user and group
- udev rules for RTL-SDR USB access
- A systemd service that runs the receiver continuously (auto-restarts on failure)
- An hourly timer that decodes captured packets to text files
- Systemd hardening (read-only filesystem, no new privileges, private /tmp)

### Service commands

```bash
sudo systemctl status elster          # check receiver status
sudo journalctl -u elster -f          # watch live output
ls /var/lib/elster/*.pcap             # list captures
sudo systemctl start elster-decode    # decode now (also runs hourly)
cat /var/lib/elster/decoded-*.txt     # read decoded output
```

## Multiple RTL-SDR dongles

If you have more than one RTL-SDR (e.g. one for gr-elster and one for rtl_433), assign each a unique serial number:

```bash
# Plug in one dongle at a time
nix-shell -p rtl-sdr --run "rtl_eeprom -s elster"
# Replug, then the next one
nix-shell -p rtl-sdr --run "rtl_eeprom -s rtl433"
```

Then configure each application to use its dongle:

```nix
# gr-elster
services.elster = {
  enable = true;
  deviceSerial = "elster";
};
```

```bash
# rtl_433
rtl_433 -d :rtl433
```

For local testing on macOS/Linux:

```bash
ELSTER_DEV_ARGS="serial=elster" nix run .#elster-rx
```

## Broadcast schedule

Meters in the mesh transmit usage data every six hours. The schedule depends on your region. For example, in eastern Ontario the broadcasts start at:

| UTC   | Eastern (EST) |
|-------|---------------|
| 05:30 | 00:30 AM      |
| 11:30 | 06:30 AM      |
| 17:30 | 12:30 PM      |
| 23:30 | 06:30 PM      |

You'll see individual packets throughout the day as meters relay data through the mesh, but the full meter readings with hourly consumption data arrive during these windows.

## Supported platforms

- `x86_64-linux`
- `aarch64-linux` (Raspberry Pi 4/5)
- `x86_64-darwin` (macOS Intel)
- `aarch64-darwin` (macOS Apple Silicon)

## Credits

All the signal processing and decoding work is by [Clayton Smith (argilo)](https://github.com/argilo/gr-elster). This repo is just a Nix flake wrapping his work for easy deployment.
