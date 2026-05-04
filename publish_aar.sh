#!/bin/bash
set -e

REPO="build/host/outputs/repo"
GROUP="com/example/my_cccd_module"
OLD="flutter_release"
NEW="nfc_cccd_module"
VERSION="1.0"

OLD_DIR="$REPO/$GROUP/$OLD"
NEW_DIR="$REPO/$GROUP/$NEW"

# Tính lại checksum cho file text đã sửa nội dung
checksum() {
    local f="$1"
    md5 -q "$f"               > "${f}.md5"
    shasum -a 1   "$f" | awk '{print $1}' > "${f}.sha1"
    shasum -a 256 "$f" | awk '{print $1}' > "${f}.sha256"
    shasum -a 512 "$f" | awk '{print $1}' > "${f}.sha512"
}

echo "==> Renaming '$OLD' → '$NEW'..."

rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR/$VERSION"

# Copy + rename tất cả file trong version folder (kể cả checksum files của binary)
for f in "$OLD_DIR/$VERSION/"*; do
    fname=$(basename "$f")
    new_fname="${fname/$OLD/$NEW}"
    cp "$f" "$NEW_DIR/$VERSION/$new_fname"
done

# Cập nhật nội dung POM
POM="$NEW_DIR/$VERSION/${NEW}-${VERSION}.pom"
sed -i '' "s|<artifactId>${OLD}</artifactId>|<artifactId>${NEW}</artifactId>|g" "$POM"
checksum "$POM"
echo "    POM updated."

# Cập nhật nội dung .module (thay toàn bộ tên cũ, kể cả trong "name"/"url" của từng file)
MODULE="$NEW_DIR/$VERSION/${NEW}-${VERSION}.module"
sed -i '' "s|${OLD}|${NEW}|g" "$MODULE"
checksum "$MODULE"
echo "    .module updated."

# Tạo maven-metadata.xml mới
META="$NEW_DIR/maven-metadata.xml"
cat > "$META" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>com.example.my_cccd_module</groupId>
  <artifactId>${NEW}</artifactId>
  <versioning>
    <release>${VERSION}</release>
    <versions>
      <version>${VERSION}</version>
    </versions>
    <lastUpdated>$(date +%Y%m%d%H%M%S)</lastUpdated>
  </versioning>
</metadata>
EOF
checksum "$META"
echo "    maven-metadata.xml created."

# Xoá thư mục flutter_release cũ
rm -rf "$OLD_DIR"

echo ""
echo "==> Done!"
echo "    Artifact: com.example.my_cccd_module:${NEW}:${VERSION}"
echo "    Consumer dùng:"
echo "      implementation 'com.example.my_cccd_module:${NEW}:${VERSION}'"
