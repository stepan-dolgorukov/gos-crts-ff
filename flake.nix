{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      certs = {
        root = pkgs.fetchurl {
          url = "https://gu-st.ru/content/Other/doc/russian_trusted_root_ca.cer";
          hash = "sha256-k2pD/qbo5SW8wPgazZw9IbT8S5torOp5BtaYAFr8ZQQ=";
        };
        sub = pkgs.fetchurl {
          url = "https://gu-st.ru/content/Other/doc/russian_trusted_sub_ca.cer";
          hash = "sha256-8K5YnzZ3TynvNkj3mEsI1C/M5vH/7rYjbXc9rrJ0TqY=";
        };
      };

      # Without the :? guard this silently becomes /.local/share under a systemd
      # unit or `env -i`, and the wrapper dies on mkdir with a bare EACCES.
      profile = "\${XDG_DATA_HOME:-\${HOME:?set HOME or XDG_DATA_HOME}/.local/share}/firefox-esr-gos";
      certutil = "${pkgs.nss.tools}/bin/certutil";

      # Honouring a user-supplied profile would mean re-implementing Firefox's
      # argument parsing (one or two dashes, case-insensitive) just to know which
      # database to seed; get it subtly wrong and the browser runs with no trust
      # anchors at all. Refuse those flags instead and point at XDG_DATA_HOME.
      rejectProfileArgs = ''
        for arg; do
          case ''${arg,,} in
            -p | --p | -profile | --profile | -profilemanager | --profilemanager)
              echo "firefox-esr-gos: pins its own profile; set XDG_DATA_HOME to relocate it" >&2
              exit 2
              ;;
          esac
        done
      '';

      # Firefox's Certificates.Install policy installs certificates with empty NSS
      # trust flags (153.4.0esr), so the browser still rejects them. Seed the
      # profile's own DB instead: the root as an SSL anchor, the sub CA untrusted
      # and only present so chains complete when a server omits it.
      #
      # Seeding must never keep the browser from starting: with a primary
      # password set, certutil cannot log in to write trust flags, so it is run
      # with stdin closed (it would otherwise prompt and hang) and a failure is
      # only reported.
      seedCerts = ''
        prof="${profile}"
        mkdir -p "$prof"
        seed() {
          ${certutil} -A -a -t C,, -n "Russian Trusted Root CA" -i ${certs.root} -d "sql:$prof" &&
            ${certutil} -A -a -t ,, -n "Russian Trusted Sub CA" -i ${certs.sub} -d "sql:$prof"
        }
        seed </dev/null ||
          echo "firefox-esr-gos: could not trust the MinCifry CAs in $prof (primary password?)" >&2
      '';

      firefox-esr-gos = pkgs.firefox-esr.overrideAttrs (old: {
        makeWrapperArgs = old.makeWrapperArgs ++ [
          "--run"
          rejectProfileArgs
          "--run"
          seedCerts
          "--append-flags"
          ''--profile "${profile}"''
        ];
      });

      launcher = "bin/firefox-esr";
    in
    {
      packages.${system} = {
        default = firefox-esr-gos;
        inherit firefox-esr-gos;
      };

      checks.${system} = {
        certs = pkgs.runCommand "gos-crts-ff-certs-check" {
          nativeBuildInputs = [ pkgs.openssl ];
        } ''
          fp() { openssl x509 -in "$1" -noout -fingerprint -sha1 | cut -d= -f2; }
          [ "$(fp ${certs.root})" = 8F:F9:15:CC:AB:7B:C1:6F:8C:5C:80:99:D5:3E:0E:11:5B:3A:EC:2F ]
          [ "$(fp ${certs.sub})" = 33:5D:43:F5:34:51:B7:81:53:5F:F3:88:2D:F7:13:D3:C1:4F:8A:01 ]

          # After "$@", so an explicit --profile takes precedence over ours.
          grep -qE '"\$@" +--profile' ${firefox-esr-gos}/${launcher}
          grep -qF -- '--profile "${profile}"' ${firefox-esr-gos}/${launcher}

          msg=$(env -u HOME -u XDG_DATA_HOME ${firefox-esr-gos}/${launcher} 2>&1 || true)
          case $msg in
            *"set HOME or XDG_DATA_HOME"*) ;;
            *) echo "no HOME guard: $msg" && exit 1 ;;
          esac

          # Firefox accepts these with one or two dashes, in any case.
          for flag in -P -p --p -profile --Profile -ProfileManager --profilemanager; do
            msg=$(timeout 60 ${firefox-esr-gos}/${launcher} $flag 2>&1 || true)
            case $msg in
              *"set XDG_DATA_HOME to relocate"*) ;;
              *) echo "$flag not refused: $msg" && exit 1 ;;
            esac
          done

          touch $out
        '';

        integration = pkgs.runCommand "gos-crts-ff-integration" {
          nativeBuildInputs = [
            pkgs.nss.tools
            pkgs.openssl
          ];
        } ''
          export HOME=$TMPDIR/home MOZ_DISABLE_CONTENT_SANDBOX=1 MOZ_ENABLE_WAYLAND=0
          mkdir -p "$HOME"

          ssl() { certutil -L -d "sql:$prof" -n "$1" | sed -n '/SSL Flags:/,/Email Flags:/p'; }
          der() { openssl x509 -in "$1" -outform DER | sha256sum | cut -d' ' -f1; }
          same() {
            certutil -L -d "sql:$prof" -n "$1" -a > $TMPDIR/got.pem
            [ "$(der $TMPDIR/got.pem)" = "$(der $2)" ]
          }
          trusted() {
            # Presence is not enough: an installed certificate with empty trust
            # flags still fails every handshake.
            certutil -V -u L -n "Russian Trusted Root CA" -d "sql:$prof"
            ssl "Russian Trusted Root CA" | grep -q "Trusted CA"
            ! ssl "Russian Trusted Sub CA" | grep -q "Trusted CA"
            same "Russian Trusted Root CA" ${certs.root}
            same "Russian Trusted Sub CA" ${certs.sub}
          }

          timeout 600 ${firefox-esr-gos}/${launcher} \
            --headless --screenshot $TMPDIR/pinned.png about:blank
          prof="$HOME/.local/share/firefox-esr-gos"
          # prefs.js, not the directory: the wrapper's own mkdir -p creates the
          # latter even when Firefox goes on to use some other profile.
          [ -s "$prof/prefs.js" ]
          [ ! -e "$HOME/.config/mozilla/firefox/profiles.ini" ]
          trusted

          # XDG_DATA_HOME relocates the profile, and a primary password there
          # costs the trust anchors but must never keep the browser from
          # starting.
          echo secret > $TMPDIR/pw
          mkdir -p $TMPDIR/xdg/firefox-esr-gos
          certutil -N -d "sql:$TMPDIR/xdg/firefox-esr-gos" -f $TMPDIR/pw
          XDG_DATA_HOME=$TMPDIR/xdg timeout 600 ${firefox-esr-gos}/${launcher} \
            --headless --screenshot $TMPDIR/locked.png about:blank
          [ -s "$TMPDIR/xdg/firefox-esr-gos/prefs.js" ]

          touch $out
        '';
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [ firefox-esr-gos ];
      };
    };
}
