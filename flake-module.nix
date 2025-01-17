{emacs-builtins}: {
  lib,
  config,
  getSystem,
  flake-parts-lib,
  ...
}: let
  inherit
    (builtins)
    map
    readFile
    attrNames
    mapAttrs
    sort
    head
    ;
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.elisp-rice;

  emacsLispPackages =
    cfg.localPackages
    ++ cfg.extraPackages
    ++ lib.optionals cfg.tests.buttercup.enable cfg.tests.buttercup.packages;

  githubPlatforms = {
    "x86_64-linux" = "ubuntu-latest";
    "x86_64-darwin" = "macos-latest";
    "aarch64-darwin" = "macos-latest";
  };

  compileName = {
    elispName,
    emacsName,
  }: "${elispName}-compile-${emacsName}";

  buttercupDrvName = emacsName: "test-buttercup-with-${emacsName}";

  makeMatrixForArchAndOs = arch: os: let
    sysCfg = (getSystem arch).elisp-rice;

    makeMatrixEntry = {
      emacs,
      elispName,
    }:
      {
        inherit arch os emacs;
        target = elispName;
      }
      // (
        lib.optionalAttrs cfg.tests.buttercup.enable {
          test-type = "run";
          test-derivation = buttercupDrvName emacs;
        }
      );

    generateEntriesForPackage = elispName:
      lib.pipe (sysCfg.supportedEmacsPackageSet.${elispName}) [
        attrNames
        (map (emacs: makeMatrixEntry {inherit emacs elispName;}))
      ];
  in
    lib.pipe cfg.localPackages [
      (map generateEntriesForPackage)
      lib.flatten
    ];
in {
  config = {
    flake = {
      melpaRecipes = lib.genAttrs cfg.localPackages (
        name:
          readFile (
            (
              if cfg.melpa == null
              then abort "You need to set elisp-rice.melpa to use this functionality"
              else cfg.melpa
            )
            + "/recipes/${name}"
          )
      );

      github = {
        matrix = {
          include = lib.pipe githubPlatforms [
            (lib.getAttrs (lib.intersectLists cfg.github.systems (attrNames githubPlatforms)))
            (lib.mapAttrsToList makeMatrixForArchAndOs)
            lib.flatten
          ];
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

      registries = mkOption {
        type = types.listOf types.attrs;
        description = lib.mdDoc ''
          Package registries for twist
        '';
      };

      lockDir = mkOption {
        type = types.nullOr types.path;
        description = lib.mdDoc ''
          Directory containing lock files for twist
        '';
        default = null;
      };

      extraPackages = mkOption {
        type = types.listOf types.str;
        description = lib.mdDoc ''
          List of Emacs Lisp packages added to the environment.
        '';
        default = [];
      };

      tests = {
        buttercup = {
          enable = mkEnableOption "buttercup";

          command = mkOption {
            type = types.str;
            description = lib.mdDoc ''
              Shell command to run for the tests.
            '';
            default = "emacs -batch -l buttercup -f buttercup-run-discover \"$PWD\"";
          };

          packages = mkOption {
            type = types.listOf types.str;
            description = lib.mdDoc ''
              List of Emacs Lisp packages added to the test environment.
            '';
            default = ["buttercup"];
          };
        };
      };

      melpa = mkOption {
        type = types.nullOr types.path;
        description = lib.mdDoc ''
          Path to the MELPA repository. This is needed for melpazoid support.
        '';
        default = null;
      };

      github = {
        systems = mkOption {
          type = types.listOf types.str;
          description = lib.mdDoc ''
            The target systems for which the CI matrix will be generated.
            Note that GitHub Actions only supports a limited set of operating
            systems and architectures, and unsupported systems are ignored
            anyway.

            Set this value if you want to skip checks on platforms where Nix run
            slower (e.g. Darwin) or your package explicitly targets certain
            operating systems.

            You can use [nix-systems](https://github.com/nix-systems/nix-systems)
            to allow overriding the target systems by the user.
          '';
          default = attrNames githubPlatforms;
        };
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
        {
          emacs-lowest = sysCfg.emacsPackageSet.${sysCfg.minEmacsVersion};
        }
        // (lib.filterAttrs (
            _: emacsPackage:
              lib.versionAtLeast emacsPackage.version sysCfg.minEmacsVersion
          )
          sysCfg.emacsPackageSet);

      lowestVersionFromAttrs = packageSet:
        lib.pipe packageSet [
          builtins.attrValues
          (lib.sort (a: b: a.version < b.version))
          builtins.head
        ];

      withEmacsLowestAttr = packageSet:
        packageSet
        // {
          emacs-lowest = lowestVersionFromAttrs packageSet;
        };

      # To get packageInputs of the Emacs environment, twist.nix needs to be run
      # in build mode, which means you cannot evaluate this until the metadata
      # is available in the lock directory.
      lowestEmacsVersionForPackage = elispName:
        defaultEmacsEnv.packageInputs.${elispName}.packageRequires.emacs;

      emacsPackageSetForPackage = elispName: let
        minEmacsVersion = lowestEmacsVersionForPackage elispName;
      in
        lib.filterAttrs (_: emacsPackage: lib.versionAtLeast emacsPackage.version minEmacsVersion) sysCfg.emacsPackageSet;

      makeAttrs = g:
        lib.pipe cfg.localPackages [
          (map (
            elispName:
              lib.mapAttrsToList (
                emacsName: emacsPackage:
                  g emacsName emacsPackage elispName
              ) (withEmacsLowestAttr (emacsPackageSetForPackage elispName))
          ))
          lib.flatten
          lib.listToAttrs
        ];

      makeEmacsEnv = emacsPackage:
        (
          pkgs.emacsTwist {
            inherit emacsPackage;
            nativeCompileAheadDefault = false;
            initFiles = [];
            extraPackages = emacsLispPackages;
            initialLibraries =
              emacs-builtins.lib.builtinLibrariesOfEmacsVersion
              emacsPackage.version;
            inherit (cfg) registries;
            inherit (cfg) localPackages;
            inherit (cfg) lockDir;
            inputOverrides = lib.genAttrs cfg.localPackages (_: {
              inherit (cfg) src;
              mainIsAscii = true;
            });
            persistMetadata = true;
            exportManifest = false;
          }
        )
        .overrideScope (_xself: xsuper: {
          elispPackages = xsuper.elispPackages.overrideScope (
            _eself: esuper:
              mapAttrs (ename: epkg:
                epkg.overrideAttrs (_: {
                  # Skip the check by default but enable it on a target package
                  # using `overrideAttrs`.
                  doCheck = false;
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
          enableElispPackages = mkEnableOption (lib.mdDoc ''
            Enable the outputs for individual Emacs Lisp packages.

            You have to set this to false when you initialize the lock directory.
          '');

          emacsPackageSet = mkOption {
            type = types.uniq (types.lazyAttrsOf types.package);
            description = lib.mdDoc ''
              An attribute set of Emacs packages to build and test packages with
            '';
          };

          defaultEmacsPackage = mkOption {
            type = types.package;
            description = lib.mdDoc ''
              Package used for various tasks.

              It should be an Emacs version that is supported by all of the
              local packages. Thus, a normal value would be the latest stable
              release of Emacs or a snapshot from one of the development
              branches.
            '';
          };

          supportedEmacsPackageSet = mkOption {
            type = types.lazyAttrsOf (types.lazyAttrsOf types.package);
            description = lib.mdDoc ''
              An attribute set of Emacs package sets for each local package
            '';
            readOnly = true;
            default = lib.genAttrs cfg.localPackages emacsPackageSetForPackage;
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
        packages =
          if sysCfg.enableElispPackages
          then
            (
              {
                inherit byte-compile;
              }
              // (lib.mapAttrs' (
                  emacsName: emacsPackage:
                    lib.nameValuePair "${emacsName}-with-packages"
                    (makeEmacsEnv emacsPackage)
                )
                filteredEmacsPackageSet)
              // lib.optionalAttrs cfg.tests.buttercup.enable (
                lib.mapAttrs' (
                  emacsName: emacsPackage:
                    lib.nameValuePair (buttercupDrvName emacsName)
                    (
                      pkgs.writeShellApplication {
                        name = "test-buttercup";
                        runtimeInputs = [
                          (makeEmacsEnv emacsPackage)
                        ];
                        text = cfg.tests.buttercup.command;
                      }
                    )
                )
                filteredEmacsPackageSet
              )
            )
          else
            (lib.mapAttrs' (
                emacsName: emacsPackage:
                  lib.nameValuePair "lock-with-${emacsName}"
                  (makeEmacsEnv emacsPackage).generateLockDir
              )
              (withEmacsLowestAttr sysCfg.emacsPackageSet));

        devShells = lib.mkIf sysCfg.enableElispPackages (makeAttrs (
          emacsName: emacsPackage: elispName: let
            epkg = (makeEmacsEnv emacsPackage).elispPackages.${elispName};
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
        ));

        checks = lib.mkIf sysCfg.enableElispPackages (makeAttrs (
          emacsName: emacsPackage: elispName:
            lib.nameValuePair
            (compileName {inherit emacsName elispName;})
            ((makeEmacsEnv emacsPackage).elispPackages.${elispName}.overrideAttrs {
              doCheck = true;
            })
        ));
      };
    });
  };
}
