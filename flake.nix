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

      profile = "\${XDG_DATA_HOME:-$HOME/.local/share}/firefox-esr-gos";

      firefox-esr-gos =
        (pkgs.firefox-esr.override {
          extraPolicies.Certificates.Install = [
            "${certs.root}"
            "${certs.sub}"
          ];
        }).overrideAttrs
          (old: {
            makeWrapperArgs = old.makeWrapperArgs ++ [
              "--run"
              ''mkdir -p "${profile}"''
              "--add-flags"
              ''--profile "${profile}"''
            ];
          });

      policies = "lib/firefox/distribution/policies.json";
      launcher = "bin/firefox-esr";
    in
    {
      packages.${system} = {
        default = firefox-esr-gos;
        inherit firefox-esr-gos;
      };

      checks.${system} = {
        certs = pkgs.runCommand "gos-crts-ff-certs-check" {
          nativeBuildInputs = [
            pkgs.jq
            pkgs.openssl
          ];
        } ''
          jq -e --arg root ${certs.root} --arg sub ${certs.sub} \
            '.policies.Certificates.Install as $i | ($i | index($root)) and ($i | index($sub))' \
            ${firefox-esr-gos}/${policies}

          fp() { openssl x509 -in "$1" -noout -fingerprint -sha1 | cut -d= -f2; }
          [ "$(fp ${certs.root})" = 8F:F9:15:CC:AB:7B:C1:6F:8C:5C:80:99:D5:3E:0E:11:5B:3A:EC:2F ]
          [ "$(fp ${certs.sub})" = 33:5D:43:F5:34:51:B7:81:53:5F:F3:88:2D:F7:13:D3:C1:4F:8A:01 ]

          grep -qF -- '--profile "${profile}"' ${firefox-esr-gos}/${launcher}
          ! grep -qF .mozilla ${firefox-esr-gos}/${launcher}

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

          timeout 180 ${firefox-esr-gos}/${launcher} \
            --headless --screenshot $TMPDIR/shot.png about:blank

          prof="$HOME/.local/share/firefox-esr-gos"
          [ -d "$prof" ]
          [ ! -e "$HOME/.mozilla" ]

          der() { openssl x509 -in "$1" -outform DER | sha256sum | cut -d' ' -f1; }
          installed() {
            certutil -L -d "sql:$prof" \
              -n "$1 - The Ministry of Digital Development and Communications" \
              -a > $TMPDIR/got.pem
            [ "$(der $TMPDIR/got.pem)" = "$(der $2)" ]
          }
          installed "Russian Trusted Root CA" ${certs.root}
          installed "Russian Trusted Sub CA" ${certs.sub}

          touch $out
        '';
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [ firefox-esr-gos ];
      };
    };
}
