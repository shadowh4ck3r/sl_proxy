.PHONY: project assets libbox build ipa clean

SCHEME ?= SL_Proxy
PROJECT ?= SL_Proxy.xcodeproj
ARCHIVE ?= build/SL_Proxy.xcarchive
# User-space loopback variant: distinct IPA names so it can sit next to the system VPN build.
IPA_BASENAME ?= SailorsLoot-UserSpace-Test
SIGNED_IPA_NAME ?= SailorsLoot-UserSpace-Test.ipa

## Download the brand images and generate the app icon / in-app logo assets
assets:
	bash ./scripts/fetch-brand-assets.sh

## Generate SL_Proxy.xcodeproj from project.yml (requires XcodeGen)
project: assets
	xcodegen generate

## Build Frameworks/Libbox.xcframework from the pinned sing-box release (requires Go)
libbox:
	bash ./scripts/build-libbox.sh

## Compile for the iOS Simulator (no signing)
build: project
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPhone 16' \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet

## Produce the unsigned and ad-hoc signed IPAs at build/ipa/
ipa: project
	xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet
	IPA_BASENAME=$(IPA_BASENAME) SIGNED_IPA_NAME=$(SIGNED_IPA_NAME) bash ./scripts/package-unsigned-ipa.sh

clean:
	rm -rf build $(PROJECT)
