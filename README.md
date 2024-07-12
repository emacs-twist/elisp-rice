# Flake-Parts Module for Checking Emacs Lisp Packages

This is a Nix flake project that lets you configure checks for your
Emacs Lisp package. It is provided as a
[flake-parts](https://flake.parts/) module, so you can elegantly set up
CI for an Emacs Lisp package that involves non Emacs Lisp,
cross-platform code.

This repository only contains the module with minimal dependencies. For
a convoluted example and instruction, see
[rice-config](https://github.com/emacs-twist/rice-config) repository.
