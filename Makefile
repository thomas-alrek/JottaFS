# Release pipeline (see docs/releasing.md).
#   make release         build dist/JottaFS-<version>.dmg, bumping the patch version
#   make release-minor   bump the minor version instead
#   make release-major   bump the major version instead
#   make publish         tag the last build and create the GitHub release
#   make ship            build, notarize and publish the next patch version
#                        in one step (ship-minor / ship-major); needs the
#                        release notes committed first
#   make sandboxed       build a fully sandboxed app for testing (no JottaFSService:
#                        no self-update, eject in Finder) in build/sandboxed.
#                        Releases always include JottaFSService.
#   make check           build the extension code and run the checks and the
#                        regression tests (release.sh runs this first)
#   make probe VOLUME=/Volumes/<name>
#                        live write probe on a mounted JottaFS volume with the
#                        build to be released installed (needed by make ship)

.PHONY: release release-minor release-major publish ship ship-minor ship-major sandboxed check probe

release:
	scripts/build-release.sh

release-minor:
	scripts/build-release.sh --minor

release-major:
	scripts/build-release.sh --major

publish:
	scripts/publish-release.sh

ship:
	scripts/release.sh

ship-minor:
	scripts/release.sh --minor

ship-major:
	scripts/release.sh --major

sandboxed:
	xcodebuild -project JottaFS.xcodeproj -scheme JottaFS -configuration Release \
		-derivedDataPath build/sandboxed -allowProvisioningUpdates \
		JOTTAFS_SANDBOXED=YES build
	@echo "App: build/sandboxed/Build/Products/Release/JottaFS.app (delete build/sandboxed when done)"

check:
	scripts/check-xcode-sources.sh
	swift build --target JottaFSKitExtension
	swift run jottafs-checks
	swift test

probe:
	@test -n "$(VOLUME)" || { echo "Usage: make probe VOLUME=/Volumes/<JottaFS volume>"; exit 2; }
	scripts/probe-volume.sh "$(VOLUME)"
