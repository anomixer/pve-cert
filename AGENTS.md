# pve-cert - Proxmox VE 專屬憑證工具開發歷程與架構指南

本文件作為 `pve-cert` 專案的持久化記憶與開發人員指南，記錄了工程細節、防退化警告與開發歷程。

---

## 📅 開發時間軸與歷程

### 階段 1：專案獨立與三端用戶端支援
- 專為 Proxmox VE 7/8/9 原生 Console Web UI (:8006) 打造一鍵式 Local Root CA 憑證簽發工具。
- 包含 `pve-cert.sh` (PVE 伺服器端), `pve-cert-windows.bat` (Windows 客戶端), `pve-cert-linux.sh` (Linux 客戶端), `pve-cert-macos.sh` (macOS 客戶端)。

### 階段 2：三端 Client CLI 自動化模式 (-s <SERVER_IP>)
- 三端客戶端腳本支援傳入 `-s <SERVER_IP>` 參數，自動預設 `root` 使用者並跳過互動選單，達成無密碼/零互動自動部署。

### 階段 3：多 IP SAN & Tailscale 支援
- 於 `pve-cert.sh` 提示輸入 `Extra IP addresses for SAN (space-separated, e.g. Tailscale IP)`。
- 自動將實體 LAN IP、`127.0.0.1`、`localhost` 及 Tailscale/VPN IP 一併寫入 SAN 屬性中。

### 階段 4：現代 Root CA 規範加固 (v3_ca)
- 於 Root CA 生成時注入 `v3_ca` 延伸屬性（`basicConstraints = critical, CA:true` 與 `keyUsage = critical, keyCertSign, cRLSign`），確保相容於 Ubuntu 26.04+ 及 Chrome M146+ Chrome Root Store。

### 階段 5：GitHub Pages 官方網站與 GitHub Actions CI/CD
- 於 `docs/index.html` 建立深色主題展示網站與雙語 Engine。
- 建立 `.github/workflows/deploy.yml`，在 push 至 `main` 時自動構建發布至 GitHub Pages。
- 設計並加入專屬 `docs/favicon.svg` 向量圖示。

### 階段 6：既有憑證偵測與選單互動 (check_existing_cert)
- 再次執行 `pve-cert.sh` 時，自動偵測 `/etc/pve/local/pveproxy-ssl.pem`，顯示到期剩餘天數與 SAN 內容，並提供選單：`[1] Reissue / Renew`, `[2] Uninstall`, `[0] Keep & Exit`。
- 選 `1` 重用既有 Root CA（用戶端 100% 免重跑、免設定）。

### 階段 7：原廠憑證備份防護機制 (Factory Cert Backup Protection)
- **`install_cert` 原廠備份鎖定**：若 `/etc/pve/local/` 已存在先前備份 (`.bak.*`)，自動保留最初的原廠備份檔，絕不以新憑證去覆蓋舊備份。
- **`do_uninstall` 最舊備份還原 (`ls -tr`)**：反安裝還原時 100% 取用最原始、最純淨的原廠自簽憑證。

### 階段 8：save_config() — 寫入 `/etc/pve-cert/pve-cert.conf`
- `pve-cert.sh` 在 `install_cert` 完成後，新增 `save_config()` 函數，寫入 `/etc/pve-cert/pve-cert.conf`（chmod 644）。
- 內容：`SERVER_FQDN="<使用者輸入的DNS Name>"`、`SERVER_IP`、`PROFILE=pve`、`PROXY_PORTS=8006`、`PORT_OFFSET=0`。
- **路徑必須是 `/etc/pve-cert/pve-cert.conf`**，絕對不能用 `/etc/anycert/anycert.conf`（那是 anycert 專案的路徑）。
- 反安裝函數 `do_uninstall_cleanup_config()` 負責清除該檔案。

### 階段 9：使用者自訂 DNS Name → 正確 SAN + FQDN 優先偵測
- `detect_pve_info()` 分別保存 `DETECTED_HOSTNAME`（hostname -s）與 `DETECTED_FQDN`（hostname -f）。
- `confirm_info()` 讓使用者覆寫 `PVE_FQDN`（如輸入 `pvenn` 取代 `pvenest.demo.local`）。
- `generate_node_cert()` 將 `PVE_FQDN`（使用者輸入）+ `DETECTED_HOSTNAME` + `DETECTED_FQDN` 全部加入 SAN DNS（去重），確保短名稱與 FQDN 都有效。
- **三端 client scripts Step 3**：優先 SSH 讀取 `/etc/pve-cert/pve-cert.conf` 取得 `SERVER_FQDN`，才能正確讀到使用者輸入的短名稱；找不到才 fallback `hostname -f`。
  - Linux/macOS：`ssh ... 'grep "^SERVER_FQDN=" /etc/pve-cert/pve-cert.conf | cut -d= -f2 | sed s/\"//g'`
  - Windows：SSH `cat /etc/pve-cert/pve-cert.conf` 存成本地 tmp 檔，再用 `for /f "tokens=1,2 delims==" %%A in (tmp)` 解析（仿 anycert-windows.bat 的做法，避開 CMD 括號內引號截斷 Bug）。

### 階段 10：Windows UAC 自動提權（VBScript ShellExecute runas）
- `pve-cert-windows.bat` 的 Administrator 檢查改用互動式提權，對齊 anycert-windows.bat 的做法。
- 若非 Admin 執行：印出 `[INFO] This script requires Administrator privileges.` 並詢問 `Would you like to elevate to Administrator now? [y/N]`。
- 使用者按 Y → 透過 VBScript `Shell.Application.ShellExecute "%~dp0%~nx0", "%*", "", "runas", 1` 重新以管理員啟動，原視窗關閉。
- 按 N → 顯示錯誤提示並 pause 退出。

### 階段 11：Windows Bat PowerShell-Free Thumbprint（certutil -hashfile）
- 舊版用 `powershell (New-Object X509Certificate2 ...).Thumbprint` 取得指紋，在部分環境 ExecutionPolicy 限制下會失敗。
- 改用原生 `certutil -hashfile "!CA_LOCAL!" SHA1`，`skip=1 tokens=*` 取第一行雜湊值，並去除空格：`set CERT_THUMB=!CERT_THUMB: =!`。

### 階段 12：移除「是否開啟瀏覽器」互動提示
- 三端 client scripts（Windows/Linux/macOS）安裝完成後，不再詢問「Open PVE Web UI now? [y/N]」。
- 改為純文字輸出 `Open browser: https://<PVE_DNS>:8006`，讓使用者自行複製開啟。

---

## ⚠️ 開發守則
1. 保持 Bash 靜態語法檢測（`bash -n`）。
2. 保持 Windows Batch 扁平化（無括號內 goto/call）。
3. 確保原廠備份不被次級憑證覆蓋。
4. **config 檔路徑必須是 `/etc/pve-cert/pve-cert.conf`**，禁止混用 anycert 的 `/etc/anycert/anycert.conf`。
5. Windows Batch 解析含引號的設定值時，必須先 SSH `cat` 下來存成本地 tmp 檔再用 `for /f tokens=1,2 delims==` 解析，禁止在 `for /f ... in ("%%H")` 內塞含引號的字串（CMD 括號引號截斷 Bug）。
