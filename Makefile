# Release pipeline (see docs/releasing.md).
#   make release         build dist/JottaFS-<version>.dmg, bumping the patch version
#   make release-minor   bump the minor version instead
#   make release-major   bump the major version instead
#   make publish         tag the last build and create the GitHub release
#   make check           build the extension code and run the checks

.PHONY: release release-minor release-major publish check

release:
	scripts/build-release.sh

release-minor:
	scripts/build-release.sh --minor

release-major:
	scripts/build-release.sh --major

publish:
	scripts/publish-release.sh

check:
	swift build --target JottaFSKitExtension
	swift run jottafs-checks
