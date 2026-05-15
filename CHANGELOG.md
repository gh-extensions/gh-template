# Changelog

## [0.2.1](https://github.com/gh-extensions/gh-template/compare/v0.2.0...v0.2.1) (2026-05-15)


### Bug Fixes

* **tests:** export _GH_TEMPLATE_DIR in bats setup ([cd4c1a3](https://github.com/gh-extensions/gh-template/commit/cd4c1a3f0d7124146ad505f18109cc359968c77b))

## [0.2.0](https://github.com/gh-extensions/gh-template/compare/v0.1.0...v0.2.0) (2026-05-13)


### Features

* add gh-template GitHub CLI extension ([10cd36e](https://github.com/gh-extensions/gh-template/commit/10cd36e0be69b5c770c5b63b16e318e2849b8b8b))
* add ignore patterns to skip template substitution in matched files ([62475ca](https://github.com/gh-extensions/gh-template/commit/62475ca248c6447dea9b9ace81e5b2efee3d15ec))
* allow --source --force to overlay onto a non-empty DIR ([6fc882e](https://github.com/gh-extensions/gh-template/commit/6fc882e1d455fbde5fcad68022ac97c988bb6549))
* report progress with gum spin during clone and substitution ([ff03bd9](https://github.com/gh-extensions/gh-template/commit/ff03bd91b9ef286b8a038a94e108ff57bbb6e2c4))


### Bug Fixes

* don't wrap clone steps in gum spin ([8790e12](https://github.com/gh-extensions/gh-template/commit/8790e12daab9e884a9126ca06d492be41e7dca1c))
* **github:** correct action versions in update.yml ([41d7253](https://github.com/gh-extensions/gh-template/commit/41d7253d187b4f94a510a1d15a296db30a39dcf4))
* prevent gum input from consuming the config TSV as its value ([ab8f398](https://github.com/gh-extensions/gh-template/commit/ab8f3989f9ccd4cc0fd2793f08627b47d3daf819))


### Performance Improvements

* batch perl substitution into one invocation per file ([2d21f15](https://github.com/gh-extensions/gh-template/commit/2d21f15606a298f4a767dcb978b568cbf326b780))

## Changelog
