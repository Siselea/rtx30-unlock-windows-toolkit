# 鍐呯疆瀹夎锛氭瘡娆″喎鍚姩鍏?U 鐩樸€佸厤鎸夐敭

涓婃父鐢ㄦ硶鏄瘡娆″喎鍚姩浠庣嫭绔?U 鐩樿繍琛?EFI銆傝繕鏈変竴绉嶅叏鑷姩鍋氭硶锛?
* 鍦ㄥ唴缃?GPT 纾佺洏涓婂缓涓€涓皬鐨?**ESP 绫诲瀷 FAT32 闅愯棌鍒嗗尯**锛?* 鎶?EFI 绋嬪簭銆? 涓浐浠惰祫浜с€佹湰鏈洪獙璇佽繃鐨?`PROFILE.BIN` 澶嶅埗杩涘幓锛?* 鏂板缓涓€鏉℃寚鍚?`\EFI\BOOT\BOOTX64.EFI` 鐨?UEFI 鍚姩椤癸紝骞?*鎺掑埌鍥轰欢鍚姩椤哄簭绗竴**銆?
杩欐牱姣忔鍐峰惎鍔ㄥ浐浠跺厛璺戣В閿佸櫒 鈫?鑷姩瑙ｉ攣 鈫?鐩存帴鍔犺浇 Windows ESP 涓婄殑
`bootmgfw.efi`锛屾棤闇€閲嶅惎銆佹棤闇€鎸夐敭銆佹棤闇€ U 鐩樸€傚師 Windows Boot Manager 鏉＄洰淇濇寔涓嶅姩銆?
## 鍓嶆彁

- UEFI 鍚姩銆?*Secure Boot 鍏抽棴**锛堝惁鍒欑▼搴忔嫆缁濊繍琛岋級锛?- 绠＄悊鍛樻潈闄愶紙涓€娆℃€у畨瑁咃級锛?- 鑷繁鏋勫缓鐨?`BOOTX64.EFI` + `bun run firmware:assets` 鐢熸垚鐨?5 涓祫浜?  锛堣祫浜ф槸 NVIDIA 鍥轰欢/鐢熸垚浜х墿锛?*涓嶅湪鏈粨搴撻噷**锛岃 `tools/firmware/README.md`锛夛紱
- 鏈満閲囬泦鐨?`RTX-UNLOCK\PROFILE.BIN`锛堣 `docs/agent/EXTERNAL-PROFILE.md`锛夈€?
## 蹇€熷紑濮?
鍑嗗鍖呯洰褰曪細

```
package\
  EFI\BOOT\BOOTX64.EFI
  RTX-UNLOCK\
    ASSETS\   (5 涓牎楠岃繃鐨勮祫浜?
    PROFILE.BIN
    DEBUG.ON  (鍙€夛紝浠呴娆¤繍琛岀敤锛涘垹鎺夊嵆鍏ㄨ嚜鍔?
```

绠＄悊鍛?PowerShell锛?
```powershell
.\tools\windows\install-internal.ps1 -PackageDir C:\path\to\package
```

鑴氭湰浼氾細瀵煎嚭 BCD 澶囦唤 鈫?浠?C: 缂╁嚭 512MB 寤?ESP 鍨?FAT32 鍒嗗尯 鈫?澶嶅埗鍖?鈫?鍒涘缓 `RTX30 UNLOCK` 鍚姩椤瑰苟鎺掔涓€ 鈫?绉婚櫎鐩樼銆佽 GPT no-automount锛堥殣钘忓垎鍖猴級銆?
鍥為€€锛?
```powershell
.\tools\windows\remove-internal.ps1 -EntryGuid '{...}'
.\tools\windows\remove-internal.ps1 -EntryGuid '{...}' -DeletePartition
```

涓存椂鍥為€€涔熷彲浠ュ紑鏈烘寜 **F8** 閫?**Windows Boot Manager**锛圓SUS 涓绘澘锛夈€?
## 琛屼负涓庢敞鎰?
* 鍐峰惎鍔細鍥轰欢 鈫?瑙ｉ攣鍣紙鑷姩锛夆啋 Windows锛屾瘮骞虫椂澶氬嚑绉掞紱
* 鏂數鍚庨€熺巼閫夋嫨鍣ㄥ浣嶏紝鎵€浠?*姣忔鍐峰惎鍔ㄩ兘瑕侀噸鏂拌В閿?*锛堣繖鏄璁′娇鐒讹紝涓嶅啓鏄惧崱鍥轰欢锛夛紱
* 鐫＄湢/浼戠湢鍙兘澶嶄綅锛涢暱浠诲姟寤鸿鍏宠嚜鍔ㄧ潯鐪狅紝闇€瑕佹椂閲嶅惎鎭㈠锛?* Windows 澶х増鏈洿鏂?/ BIOS 鏇存柊鍙兘閲嶇疆 UEFI 鍚姩椤哄簭锛岃嫢瑙ｉ攣鍣ㄤ笉璺戜簡锛屾妸
  `RTX30 UNLOCK` 閲嶆柊鎺掔涓€鍗冲彲锛坄bcdedit /set {fwbootmgr} displayorder {GUID} /addfirst`锛夛紱
* **涓嶈鏍煎紡鍖?鍔犲瘑閭ｄ釜闅愯棌鍒嗗尯**锛堥噷闈㈡湁璧勪骇鍜屾湰鏈?profile锛夈€?
## 鍒嗗尯鍙傛暟

| 椤圭洰 | 鍊?|
|---|---|
| 澶у皬 | 榛樿 512MB锛坄-SizeMB`锛?|
| 鏂囦欢绯荤粺 | FAT32 |
| GPT 绫诲瀷 | `c12a7328-f81f-11d2-ba4b-00a0c93ec93b`锛圗FI System Partition锛?|
| 鐩樼 | 瀹夎瀹屾垚鍚庣Щ闄?|
| GPT 灞炴€?| `0x8000000000000000`锛坣o automount锛?|
| 鍚姩椤?| `RTX30 UNLOCK`锛岃澶?璇ュ垎鍖猴紝璺緞=`\EFI\BOOT\BOOTX64.EFI` |

绋嬪簭鍙帴鍙?USB 璁惧鎴?GPT ESP 绫诲瀷鍒嗗尯浣滀负寮曞鍗凤紙`GU_SSD_EXPERIMENT`锛夛紝
鎵€浠ュ垎鍖鸿鐢?ESP 绫诲瀷 GUID銆?
