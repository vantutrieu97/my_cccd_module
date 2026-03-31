# WORKSPACE CONTEXT - my_cccd_module

Muc tieu: Luu context rieng cho repo `my_cccd_module` de giam scan code lap lai.

## 1) Repo Info

- Path: `/Users/tungu/Documents/source_code/my_cccd_module`
- Tech: Flutter module
- Branch hien tai: `main`
- Last updated: 2026-03-31

## 2) Current Snapshot

- Vai tro: Module scan/doc du lieu CCCD.
- Thay doi gan day:
  - `lib/main.dart` (modified)
  - `lib/mrtd_data.dart` (added)
  - `lib/mrz_scanner.dart` (deleted)
  - `lib/mrz_scanner_screen.dart` (deleted)
  - `pubspec.yaml`, `pubspec.lock` (modified)
  - `ANDROID_INTEGRATION_GUIDE.md` (untracked)
- Luu y:
  - `flutter_01.log` la file log, khong commit neu khong can.

## 3) Architecture Notes

- Day la Flutter module duoc tich hop vao Android app host.
- Luong tong quat:
  - Android host goi Flutter module.
  - Flutter module xu ly scan/du lieu CCCD.
  - Ket qua tra nguoc ve host app.

## 4) Active Decisions Log

- [2026-03-31] Tach context theo tung repo:
  - Context: Can tai su dung ngu canh nhanh cho moi repo.
  - Chosen option: 2 file `WORKSPACE_CONTEXT.md`, moi repo 1 file.
  - Why: Giam scan lai va de handoff moi phien.
  - Impact: De cap nhat va theo doi thay doi chinh xac hon.

## 5) TODO / Next Actions

- [ ] Xac nhan luong moi thay cho `mrz_scanner*`.
- [ ] Kiem tra lai dong bo `pubspec.yaml` va code scan.
- [ ] Chot test case smoke cho luong scan.

## 6) Session Handoff

- Muc tieu phien:
- Da lam:
- Dang vo:
- Blockers:
- Lenh test da chay:
- Ket qua:

## 7) Fast Commands

- `flutter pub get`
- `flutter analyze`
- `flutter test`

## 8) Update Rule (Quan trong)

- Moi khi co thay doi duoc apply vao repo nay, cap nhat lai it nhat cac muc 2, 4, 6.
- Khong luu secret/token vao file nay.
