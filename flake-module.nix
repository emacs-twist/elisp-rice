{emacs-builtins}: {
  lib,
  config,
  getSystem,
  flake-parts-lib,
  ...
}: let
  inherit
    (builtins)
    isString
    map
    readFile
    attrNames
    mapAttrs
    elem
    sort
    head
    ;
  inherit (lib) mkOption types;
  cfg = config.elisp-rice;

  githubPlatforms = {
    "x86_64-linux" = "ubuntu-latest";
    "x86_64-darwin" = "macos-latest";
    "aarch64-darwin" = "macos-latest";
  };

  compileName = {
    elispName,
    emacsName,
  }: "${elispName}-compile-${emacsName}";

  makeMatrixForArchAndOs = arch: os: let
    sysCfg = (getSystem arch).elisp-rice;

    # A list of Emacs versions (actually attribute names) that are
    # greater than the minimum supported Emacs version on the system.
    supportedEmacsVersions = lib.pipe sysCfg.emacsPackageSet [
      (lib.filterAttrs (
        _: emacsPackage:
          lib.versionAtLeast
          emacsPackage.version
          sysCfg.minEmacsVersion
      ))
      attrNames
    ];

    matrixForEmacs = emacs:
      map (
        elispName: {
          inherit arch os emacs;
          target = elispName;
        }
      )
      cfg.localPackages;
  in
    map matrixForEmacs supportedEmacsVersions;
in {
  config = {
    flake = {
      melpaRecipes = lib.genAttrs cfg.localPackages (
        name:
          readFile (cfg.melpa + "/recipes/${name}")
      );

      github = {
        matrix = {
          include = lib.flatten (
            lib.mapAttrsToList makeMatrixForArchAndOs githubPlatforms
          );
        };
      };
    };
  };

  options = {
    elisp-rice = {
      localPackages = mkOption {
        type = types.nonEmptyListOf types.nonEmptyStr;
        description = lib.mdDoc ''
          A list of Emacs Lisp packages in this repository
        '';
      };

      src = mkOption {
        type = types.path;
        description = lib.mdDoc ''
          Directory containing source code
        '';
      };

      melpa = mkOption {
        type = types.path;
        description = lib.mdDoc ''
          Path to the melpa repository to discover recipes
        '';
      };

      lockDir = mkOption {
        type = types.nullOr types.path;
        description = lib.mdDoc ''
          Directory containing lock files for twist
        '';
        default = null;
      };

      lockInputName = mkOption {
        type = types.nullOr types.str;
        description = lib.mdDoc ''
          If the lock directory is an input of the root flake, this should
          be the input name.
        '';
        default = null;
      };
    };

    perSystem = flake-parts-lib.mkPerSystemOption ({
      config,
      pkgs,
      ...
    }: let
      sysCfg = config.elisp-rice;

      byte-compile = pkgs.writeShellApplication {
        name = "elisp-byte-compile";
        text = ''
          if [[ $# -eq 0 ]]
          then
            echo "You have to specify at least one elisp file as argument" >&2
            name=$(basename "$0")
            echo "Usage: $name FILE..."
            exit 1
          fi

          ret=0

          printf >&2 "[%s] Running byte-compile...\n" "$(date +'%Y-%m-%d %H:%M:%S')"

          for file in "$@"
          do
            if emacs -batch --no-site-file -L . \
                 --eval "(setq byte-compile-error-on-warn t)" \
                       -f batch-byte-compile "$file"
            then
              printf >&2 "✅[OK] %s\t(byte-compile)\n" "$file"
            else
              printf >&2 "❌[NG] %s\t(byte-compile)\n" "$file"
              ret=1
            fi
          done

          exit $ret
        '';
      };

      filteredEmacsPackageSet =
        lib.filterAttrs (
          _: emacsPackage:
            lib.versionAtLeast emacsPackage.version sysCfg.minEmacsVersion
        )
        sysCfg.emacsPackageSet;

      makeAttrs = g:
        lib.pipe filteredEmacsPackageSet [
          attrNames

          (map (emacsName: (map (g emacsName) cfg.localPackages)))

          lib.flatten

          lib.listToAttrs
        ];

      makeEmacsEnv = emacsPackage:
        (
          pkgs.emacsTwist {
            inherit emacsPackage;
            nativeCompileAheadDefault = false;
            initFiles = [];
            extraPackages = cfg.localPackages;
            initialLibraries =
              emacs-builtins.lib.builtinLibrariesOfEmacsVersion
              emacsPackage.version;
            registries = [
              {
                type = "melpa";
                path = cfg.melpa + "/recipes";
              }
              {
                type = "archive";
                url = "https://elpa.gnu.org/packages/";
              }
            ];
            inherit (cfg) localPackages;
            inherit (cfg) lockDir;
            inputOverrides = lib.genAttrs cfg.localPackages (_: {
              inherit (cfg) src;
              mainIsAscii = true;
            });
            exportManifest = false;
            postCommandOnGeneratingLockDir =
              if isString cfg.lockInputName && cfg.lockInputName != ""
              then "nix flake lock --update-input ${cfg.lockInputName}"
              else null;
          }
        )
        .overrideScope (_xself: xsuper: {
          elispPackages = xsuper.elispPackages.overrideScope (
            _eself: esuper:
              mapAttrs (ename: epkg:
                epkg.overrideAttrs (_: {
                  # dontByteCompile = true;

                  doCheck = elem ename cfg.localPackages;
                  checkPhase = ''
                    printf >&2 "Testing with %s\n" "$(emacs --version | grep -E 'GNU Emacs [0-9]+')"

                    for f in *.el; do
                      if [[ $f = *-autoloads.el ]]; then
                        continue
                      fi
                      echo >&2 "[elisp-rice] Byte-compiling $f..."
                      emacs -batch --no-site-file -L . \
                        --eval "(setq byte-compile-error-on-warn t)" \
                        -f batch-byte-compile "$f"
                      printf >&2 "✅[OK] %s\t(%s)\n" "$f" byte-compile
                    done

                    echo >&2 "[elisp-rice] Loading ${ename}.elc..."
                    emacs -batch --no-site-file -L . -l "${ename}.elc"
                    printf >&2 "✅[OK] %s\t(%s)\n" "${ename}.elc" load
                  '';
                }))
              esuper
          );
        });

      defaultEmacsEnv = makeEmacsEnv sysCfg.defaultEmacsPackage;

      calculatedMinEmacsVersion = lib.pipe cfg.localPackages [
        (map (ename: defaultEmacsEnv.packageInputs.${ename}.packageRequires.emacs))
        (sort lib.versionOlder)
        head
      ];
    in {
      options = {
        elisp-rice = {
          emacsPackageSet = mkOption {
            type = types.uniq (types.lazyAttrsOf types.package);
            description = lib.mdDoc ''
              An attribute set of Emacs packages to build and test packages with
            '';
          };

          defaultEmacsPackage = mkOption {
            type = types.package;
            description = lib.mdDoc ''
              Package used for various tasks
            '';
          };

          minEmacsVersion = mkOption {
            type = types.str;
            description = lib.mdDoc ''
              Minimum Emacs version that satisfies at least one of the packages
            '';
            default = calculatedMinEmacsVersion;
          };
        };
      };

      config = {
        pre-commit.settings.hooks.elisp-byte-compile = {
          description = "Byte-compile Emacs Lisp files";
          entry = "${byte-compile}/bin/elisp-byte-compile";
          files = "\\.el$";
        };

        packages =
          lib.mapAttrs' (
            emacsName: emacsPackage:
              lib.nameValuePair "${emacsName}-with-packages"
              (makeEmacsEnv emacsPackage)
          )
          filteredEmacsPackageSet;

        devShells = makeAttrs (
          emacsName: elispName: let
            emacsEnv = makeEmacsEnv sysCfg.emacsPackageSet.${emacsName};
            epkg = emacsEnv.elispPackages.${elispName};
          in
            lib.nameValuePair
            "${emacsName}-for-${elispName}"
            (pkgs.mkShell {
              nativeBuildInputs = [
                byte-compile
                pkgs.entr
              ];
              inputsFrom = [
                epkg
              ];
            })
        );

        checks = makeAttrs (
          emacsName: elispName:
            lib.nameValuePair
            (compileName {inherit emacsName elispName;})
            (makeEmacsEnv sysCfg.emacsPackageSet.${emacsName}).elispPackages.${elispName}
        );
      };
    });
  };
}
