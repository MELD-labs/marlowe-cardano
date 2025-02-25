{ pkgs
, checkMaterialization
, system ? builtins.currentSystem
, config ? { allowUnfreePredicate = (import ../lib/unfree.nix).unfreePredicate; }
, sources
, enableHaskellProfiling
}:
let
  inherit (pkgs) stdenv;

  gitignore-nix = pkgs.callPackage sources.gitignore-nix { };

  # { index-state, compiler-nix-name, project, projectPackages, packages, extraPackages }
  haskell = pkgs.callPackage ./haskell {
    inherit gitignore-nix sources;
    inherit checkMaterialization enableHaskellProfiling;
    inherit (sources) actus-tests;

    # This ensures that the utility scripts produced in here will run on the current system, not
    # the build system, so we can run e.g. the darwin ones on linux
    inherit (pkgs.evalPackages) writeShellScript;
  };

  #
  # additional haskell packages from ./nix/pkgs/haskell-extra
  #
  exeFromExtras = x: haskell.extraPackages."${x}".components.exes."${x}";
  cabal-install = haskell.extraPackages.cabal-install.components.exes.cabal;
  cardano-repo-tool = exeFromExtras "cardano-repo-tool";
  stylish-haskell = exeFromExtras "stylish-haskell";
  hlint = exeFromExtras "hlint";
  haskell-language-server = exeFromExtras "haskell-language-server";
  haskell-language-server-wrapper = pkgs.writeShellScriptBin "haskell-language-server-wrapper" ''${haskell-language-server}/bin/haskell-language-server "$@"'';
  hie-bios = exeFromExtras "hie-bios";

  # These are needed to pull the cardano-cli and cardano-node in the nix-shell.
  inherit (haskell.project.hsPkgs.cardano-cli.components.exes) cardano-cli;
  inherit (haskell.project.hsPkgs.cardano-node.components.exes) cardano-node;

  #
  # dev convenience scripts
  #
  fixPurty = pkgs.callPackage (sources.plutus-apps + "/nix/pkgs/fix-purty") { inherit purty; };
  fixStylishHaskell = pkgs.callPackage (sources.plutus-apps + "/nix/pkgs/fix-stylish-haskell") { inherit stylish-haskell; };
  fixPngOptimization = pkgs.callPackage (sources.plutus-apps + "/nix/pkgs/fix-png-optimization") { };
  updateMaterialized = pkgs.writeShellScriptBin "updateMaterialized" ''
    # This runs the 'updateMaterialize' script in all platform combinations we care about.
    # See the comment in ./haskell/haskell.nix

    # Update the linux files (will do for all unixes atm).
    $(nix-build default.nix -A marlowe.haskell.project.plan-nix.passthru.updateMaterialized --argstr system x86_64-linux)
    $(nix-build default.nix -A marlowe.haskell.project.plan-nix.passthru.updateMaterialized --argstr system x86_64-darwin)
    $(nix-build default.nix -A marlowe.haskell.project.plan-nix.passthru.updateMaterialized --argstr system windows)
    $(nix-build default.nix -A marlowe.haskell.project.projectCross.mingwW64.plan-nix.passthru.updateMaterialized --argstr system x86_64-linux)

    # This updates the sha files for the extra packages
    $(nix-build default.nix -A marlowe.haskell.extraPackages.updateAllShaFiles --argstr system x86_64-linux)
    $(nix-build default.nix -A marlowe.haskell.extraPackages.updateAllShaFiles --argstr system x86_64-darwin)
  '';
  updateClientDeps = pkgs.callPackage (sources.plutus-apps + "/nix/pkgs/update-client-deps") {
    inherit purs psc-package spago spago2nix;
  };

  #
  # sphinx python packages
  #
  sphinx-markdown-tables = pkgs.python3Packages.callPackage (sources.plutus-apps + "/nix/pkgs/sphinx-markdown-tables") { };
  sphinxemoji = pkgs.python3Packages.callPackage (sources.plutus-apps + "/nix/pkgs/sphinxemoji") { };

  # By default pre-commit-hooks.nix uses its own pinned version of nixpkgs. In order to
  # to get it to use our version we have to (somewhat awkwardly) use `nix/default.nix`
  # to which both `nixpkgs` and `system` can be passed.
  nix-pre-commit-hooks = (pkgs.callPackage (sources.pre-commit-hooks-nix + "/nix/default.nix") {
    inherit system;
    inherit (sources) nixpkgs;
  });

  # purty is unable to process several files but that is what pre-commit
  # does. pre-commit-hooks.nix does provide a wrapper for that but when
  # we pin our own `tools` attribute that gets overwritten so we have to
  # instead provide the wrapper.
  purty-pre-commit = pkgs.callPackage (sources.plutus-apps + "/nix/pkgs/purty-pre-commit") { inherit purty; };

  # easy-purescript-nix has some kind of wacky internal IFD
  # usage that breaks the logic that makes source fetchers
  # use native dependencies. This isn't easy to fix, since
  # the only places that need to use native dependencies
  # are deep inside, and we don't want to build the whole
  # thing native. Fortunately, we only want to build the
  # client on Linux, so that's okay. However, it does
  # mean that e.g. we can't build the client dep updating
  # script on Darwin.
  easyPS = pkgs.callPackage (sources.easy-purescript-nix) { };

  # We pull out some packages from easyPS that are a pain to get otherwise.
  # In particular, we used to build purty ourselves, but now its build is a nightmare.
  # This does mean we can't as easily control the version we get, though.
  inherit (easyPS) purty purs psc-package spago;

  # There is a spago2nix in easyPS, but it doesn't (currently) work. It doesn't
  # matter because it's actually just a thin call to spago2nix's nix build
  # script. So we can just go directly to the source and get the latest
  # version.
  #
  # It's worth periodically checking to see if the easyPS version is working
  # again. To check:
  #
  # * Replace this call with `inherit (easyPS) spago2nix;`.
  # * Run `nix-shell --run 'cd plutus-playground-client ; update-client-deps'
  #
  # If that fails, it's not ready. Rollback.
  # If it succeeds:
  #
  # * Merge your new `inherit (easyPS) spago2nix` with the one above.
  # * Remove spago2nix from flake.nix
  # * Run `nix --experimental-features 'nix-command flakes' flake lock`
  #
  spago2nix = pkgs.callPackage (sources.spago2nix) { };

  # sphinx haddock support
  sphinxcontrib-haddock = pkgs.callPackage (sources.sphinxcontrib-haddock) { pythonPackages = pkgs.python3Packages; };

  # ghc web service
  web-ghc = pkgs.callPackage (sources.plutus-apps + "/nix/pkgs/web-ghc") { inherit haskell; extraPackagesFun = ps: [ ps.marlowe ]; };

  # combined haddock documentation for all public plutus libraries
  plutus-haddock-combined =
    let
      haddock-combine = pkgs.callPackage (sources.plutus-core + "/nix/lib/haddock-combine.nix") {
        ghc = haskell.projectAllHaddock.pkg-set.config.ghc.package;
        inherit (sphinxcontrib-haddock) sphinxcontrib-haddock;
      };
    in
    pkgs.callPackage (sources.plutus-core + "/nix/pkgs/plutus-haddock-combined") {
      inherit haskell haddock-combine;
      inherit (pkgs) haskell-nix;
    };

  # Collect everything to be exported under `plutus.lib`: builders/functions/utils
  lib = rec {
    inherit gitignore-nix;
    haddock-combine = pkgs.callPackage (sources.plutus-core + "/nix/lib/haddock-combine.nix") { inherit sphinxcontrib-haddock; };
    filterNpm = pkgs.callPackage (sources.plutus-apps + "/nix/lib/filter-npm.nix") { };
    npmlock2nix = pkgs.callPackage sources.npmlock2nix { };
    buildPursPackage = pkgs.callPackage (sources.plutus-apps + "/nix/lib/purescript.nix") { inherit easyPS; inherit (pkgs) nodejs; };
    buildNodeModules = pkgs.callPackage (sources.plutus-apps + "/nix/lib/node_modules.nix") ({
      inherit npmlock2nix;
    } // pkgs.lib.optionalAttrs (stdenv.isDarwin) {
      CoreServices = pkgs.darwin.apple_sdk.frameworks.CoreServices;
      xcodebuild = pkgs.xcodebuild;
    });

  };

in
{
  inherit sphinx-markdown-tables sphinxemoji sphinxcontrib-haddock;
  inherit nix-pre-commit-hooks;
  inherit haskell cabal-install cardano-repo-tool stylish-haskell hlint haskell-language-server haskell-language-server-wrapper hie-bios cardano-cli cardano-node;
  inherit purty purty-pre-commit purs spago spago2nix;
  inherit fixPurty fixStylishHaskell fixPngOptimization updateMaterialized updateClientDeps;
  inherit web-ghc;
  inherit easyPS plutus-haddock-combined;
  inherit lib;
}
