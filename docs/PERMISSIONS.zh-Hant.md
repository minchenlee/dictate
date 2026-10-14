# Dictate 權限設定指南

Dictate 需要兩個權限：

| 權限 | 用途 | 沒有時會怎樣 |
|---|---|---|
| 麥克風 | 錄音 | 無法錄音 |
| 輔助使用 | 偵測單一修飾鍵（例如右 ⌘），並送出 ⌘V 貼上 | 右 ⌘ 沒反應；或文字只放進剪貼簿，Dictate 提示你自己按 ⌘V |

## 什麼時候要重做

- 按右 ⌘ 沒有反應，HUD 也不出現。
- 轉錄完成，但文字沒有自動貼上，只留在剪貼簿。
- 你搬過 app 位置，或重新打包後出現上面兩種情況。

## 步驟

### 1. 結束 Dictate

點選單列的 Dictate 圖示 → 結束 Dictate。

確認已經結束：

```sh
pgrep -fl Dictate    # 沒有輸出才算結束
```

### 2. 清掉舊的授權紀錄

```sh
tccutil reset Accessibility dev.mclee.dictate
tccutil reset Microphone dev.mclee.dictate
```

兩行都應該印出 `Successfully reset ...`。

### 3. 移除殘留的項目

1. 打開「系統設定 → 隱私權與安全性 → 輔助使用」。
2. 如果列表裡還有 Dictate，選取它，按下方的「−」移除。

### 4. 加入 /Applications 裡的 Dictate

1. 在同一個「輔助使用」頁面按「+」。
2. 按 ⌘⇧G，輸入 `/Applications/Dictate.app`，按「打開」。
3. 確認 Dictate 的開關是打開的。

注意：repo 裡的 `build/Dictate.app` 也是一份 Dictate。只授權 `/Applications` 那份，也只打開那份。

### 5. 打開 Dictate

```sh
open /Applications/Dictate.app
pgrep -fl Dictate    # 應該顯示 /Applications/Dictate.app/Contents/MacOS/Dictate
```

### 6. 允許麥克風

第一次錄音時，macOS 會詢問是否允許使用麥克風。按「允許」。

如果沒有跳出詢問：打開「系統設定 → 隱私權與安全性 → 麥克風」，打開 Dictate 的開關。

### 7. 檢查登入項目

1. 打開「系統設定 → 一般 → 登入項目」，確認 Dictate 在列表裡。
2. 在 Dictate 的設定 → 一般，把「登入時自動開啟」關掉，再打開一次。這樣登入項目會指向 `/Applications` 那份。

### 8. 驗證

1. 點任何一個文字欄位，例如備忘錄。
2. 按住右 ⌘，說一句話，放開。
3. 預期結果：
   - 按住時，螢幕下方出現錄音 HUD，音量條會跳動。
   - 放開後 HUD 顯示「轉錄中」。
   - 文字自動貼到游標處，剪貼簿恢復原本的內容。

如果文字沒有自動貼上，回到第 1 步重做。

## 以後更新 app

1. 先結束 Dictate。
2. 執行 `ditto build/Dictate.app /Applications/Dictate.app`。
3. 再打開 Dictate。

`bundle.sh` 用同一張 Apple Development 憑證簽名，所以授權通常會保留。如果更新後貼上失效，照上面的步驟重做。

## 查目前的授權狀態（選用）

```sh
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, auth_value from access where client = 'dev.mclee.dictate'"
```

`auth_value` 是 `2` 代表允許，`0` 代表拒絕。這個指令需要終端機有「完整磁碟取用權限」。
