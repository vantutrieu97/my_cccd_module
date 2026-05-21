#!/bin/bash
set -e

FLUTTER="${FLUTTER_HOME:-$(which flutter 2>/dev/null || echo "/Users/tungu/Documents/dev_env/flutter_3.41.6/bin/flutter")}"
MAVEN_REPO_SSH="git@github.com:vantutrieu97/my-cccd-maven-.git"
MAVEN_CLONE="/tmp/my-cccd-maven-$$"

REPO="build/host/outputs/repo"
GROUP_PATH="com/example/my_cccd_module"
OLD_ID="flutter_release"
NEW_ID="nfc_cccd_module"
VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: //;s/+.*//' | tr -d ' ')

echo "==> Version: $VERSION"
echo "==> Flutter: $FLUTTER"
echo "==> Maven repo: $MAVEN_REPO_SSH"

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo ""
echo "==> Building AAR..."
"$FLUTTER" build aar --no-debug --no-profile --build-number="$VERSION"

# ── 2. Rename flutter_release → nfc_cccd_module ───────────────────────────────
checksum() {
    local f="$1"
    md5 -q "$f"                          > "${f}.md5"
    shasum -a 1   "$f" | awk '{print $1}' > "${f}.sha1"
    shasum -a 256 "$f" | awk '{print $1}' > "${f}.sha256"
    shasum -a 512 "$f" | awk '{print $1}' > "${f}.sha512"
}

OLD_DIR="$REPO/$GROUP_PATH/$OLD_ID"
NEW_DIR="$REPO/$GROUP_PATH/$NEW_ID"

echo ""
echo "==> Renaming '$OLD_ID' → '$NEW_ID' ($VERSION)..."

rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR/$VERSION"

for f in "$OLD_DIR/$VERSION/"*; do
    fname=$(basename "$f")
    cp "$f" "$NEW_DIR/$VERSION/${fname/$OLD_ID/$NEW_ID}"
done

POM="$NEW_DIR/$VERSION/${NEW_ID}-${VERSION}.pom"
sed -i '' "s|<artifactId>${OLD_ID}</artifactId>|<artifactId>${NEW_ID}</artifactId>|g" "$POM"
checksum "$POM"

MODULE="$NEW_DIR/$VERSION/${NEW_ID}-${VERSION}.module"
sed -i '' "s|${OLD_ID}|${NEW_ID}|g" "$MODULE"
checksum "$MODULE"

cat > "$NEW_DIR/maven-metadata.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>com.example.my_cccd_module</groupId>
  <artifactId>${NEW_ID}</artifactId>
  <versioning>
    <release>${VERSION}</release>
    <versions><version>${VERSION}</version></versions>
    <lastUpdated>$(date +%Y%m%d%H%M%S)</lastUpdated>
  </versioning>
</metadata>
EOF
checksum "$NEW_DIR/maven-metadata.xml"

rm -rf "$OLD_DIR"
echo "    Done."

# ── 3. Clone Maven repo, copy artifacts, push ─────────────────────────────────
echo ""
echo "==> Cloning Maven repo..."
git clone --quiet "$MAVEN_REPO_SSH" "$MAVEN_CLONE"

echo "==> Copying artifacts..."
cp -r "$REPO/." "$MAVEN_CLONE/"

echo "==> Pushing to GitHub..."
cd "$MAVEN_CLONE"
git add .
git commit -m "publish nfc_cccd_module $VERSION"
git push --quiet

echo "==> Cleanup..."
rm -rf "$MAVEN_CLONE"

echo ""
echo "✅ Published: com.example.my_cccd_module:nfc_cccd_module:$VERSION"
echo "   implementation(\"com.example.my_cccd_module:nfc_cccd_module:$VERSION\")"
