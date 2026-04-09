#!/bin/bash
# TestFlight upload script with auto-incrementing build number
# Uploads to both cmux (com.cmuxterm.app) and cmux NIGHTLY (com.cmuxterm.app.nightly)
set -e

cd "$(dirname "$0")/.."

# Get current build number from project.yml
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed 's/.*: *"\([0-9]*\)".*/\1/')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "📱 Bumping build number: $CURRENT_BUILD → $NEW_BUILD"

# Update build number in project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CURRENT_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml

# Regenerate Xcode project
echo "⚙️  Regenerating Xcode project..."
xcodegen generate

# Export options (shared between both builds)
EXPORT_PLIST="build/ExportOptions.plist"
cat <<'EOF' > "$EXPORT_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>7WLXT3NR37</string>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndPlatform</key>
  <true/>
</dict>
</plist>
EOF

archive_and_upload() {
  local config="$1"
  local app_name="$2"
  local archive_path="build/cmux-${config}.xcarchive"

  echo ""
  echo "📦 Archiving $config ($app_name)..."
  xcodebuild -scheme cmux -configuration "$config" \
    -archivePath "$archive_path" archive \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    -quiet

  echo "🚀 Uploading $config to TestFlight..."
  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "build/export-${config}" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration

  echo "✅ $config ($app_name) build $NEW_BUILD uploaded!"
}

archive_and_upload "Release" "cmux"
archive_and_upload "Nightly" "cmux NIGHTLY"

echo ""
echo "✅ Build $NEW_BUILD uploaded to both TestFlight apps!"
