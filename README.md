# Dictate

輕量的 macOS 選單列語音輸入 app。按住右 ⌘ 說話，放開後文字會出現在游標所在的輸入框。

## 功能
- 觸發鍵：右 ⌘／⌥／⌃／⇧ 單鍵。模式：按住說話（預設），或按一下開始、再按一下送出。錄音中按 Esc 取消。
- 轉錄：任何 OpenAI 相容的 `POST {base}/audio/transcriptions`。內建 OpenAI（`gpt-transcribe`）和 OpenRouter（`openai/gpt-transcribe`）預設，也可自訂 base URL。
- API key 存在 Keychain（service `dev.mclee.dictate`，每個 API host 一把）。
- 簡轉繁：有安裝 `opencc`（`brew install opencc`）就用 `s2twp` 轉換，程式碼與網址不轉。
- 插入：剪貼簿＋⌘V，0.5 秒後還原原本的剪貼簿。

## 權限
- 麥克風：錄音。
- 輔助使用：監聽觸發鍵、送出 ⌘V。

## 開發
```sh
swift run DictateChecks           # 純邏輯測試（headless）。CLT 6.2 的 swift test 會靜默跑 0 個測試，所以改用這個 runner
scripts/bundle.sh                # 產生 build/Dictate.app（ad-hoc 簽名）
SIGN_ID="Apple Development: …" scripts/bundle.sh   # 固定簽名，重 build 不用重新授權
```
重的 build 請用 `slot run <name> "bundle" -- scripts/bundle.sh`。

## 結構
- `Sources/DictateCore`：可測的純邏輯：快捷鍵狀態機、multipart 請求與回應解析、簡轉繁遮罩、設定。
- `Tests/DictateCoreTests`：swift-testing 測試，以 `DictateChecks` 執行檔執行。
- `Sources/Dictate`：AppKit 層：選單列、HUD、錄音、全域監聽、貼上、Keychain、設定視窗。
