# pve-cert — Proxmox HTTPS，每台用戶端都受信任。一鍵設定、免網域、免連網、十年免重設。

[English](README.md) | **繁體中文**

瀏覽器的 Proxmox 憑證警告，永久消失。

伺服器一個指令，每台用戶端一個指令 —
瀏覽器顯示鎖頭，十年內持續有效，
完全離線運作，不需要任何公開網域。

---

全新安裝的 Proxmox VE 都會出現這個畫面：

![](pic/1.png)
![](pic/2.png)

---

## 檔案說明

| 檔案 | 平台 | 用途 |
|------|------|------|
| `pve-cert.sh` | Proxmox VE（節點/叢集） | 產生 Root CA + 節點憑證，安裝至 PVE |
| `pve-cert-windows.bat` | Windows 用戶端 | 下載 CA 憑證、更新 hosts、匯入 Windows 信任存放區 |
| `pve-cert-linux.sh` | Linux 用戶端（Ubuntu/Debian） | 下載 CA 憑證、更新 hosts、匯入系統與瀏覽器信任存放區 |
| `pve-cert-macos.sh` | macOS 用戶端 | 下載 CA 憑證、更新 hosts、匯入 macOS Keychain |

在 PVE 伺服器執行 `pve-cert.sh`、再在每台用戶端執行對應腳本後，警告就消失了：

![](pic/s1.png)
![](pic/s2.png)

---

## 相容性

**Proxmox VE（伺服器）**
- PVE 7.x 以上

**用戶端作業系統**

| 作業系統 | 版本 |
|----------|------|
| Windows | 10, 11（x86 / ARM） |
| Linux | Ubuntu 20.04+、Debian 11+（x86 / ARM） |
| macOS | 12 Monterey 以上（Intel / Apple Silicon） |

**瀏覽器**

| 瀏覽器 | 說明 |
|--------|------|
| Chrome / Chromium | ✅ Linux 自動匯入；Windows / macOS 跟隨系統信任 |
| Firefox | ✅ Linux 自動匯入（含 snap）；Windows / macOS 跟隨系統信任 |
| Edge | ✅ 跟隨 Windows / macOS 系統信任存放區 |
| Safari | ✅ 跟隨 macOS Keychain |

---

## 為什麼要用這個腳本？

處理 Proxmox VE Web UI TLS 憑證有幾種常見方式，下表比較各方法的差異。

### 憑證方式比較

| | **PVE 預設自簽憑證** | **ACME / Let's Encrypt (HTTP-01)** | **Let's Encrypt + Cloudflare (DNS-01)** | **商業萬用字元憑證** | **本腳本 — 自簽 CA + 用戶端信任** |
|---|---|---|---|---|---|
| **瀏覽器警告** | ❌ 預設顯示警告（可手動匯入 PVE Root CA 消除，但每年憑證更新後須每台重新匯入） | ✅ 無 | ✅ 無 | ✅ 無 | ✅ 無（完成用戶端設定後） |
| **需有公開網域** | ✅ 否 | ❌ 是 | ❌ 是 | ❌ 是 | ✅ 否 |
| **需有網際網路連線** | ✅ 否 | ❌ 是（port 80/443） | ❌ 是（DNS API） | ❌ 是 | ✅ 否 — 完全離線可用 |
| **有效期 / 更新** | 1 年，自動更新 | 90 天，自動更新 | 90 天，自動更新 | 1–2 年，手動更新 | 可設定（預設 10 年） |
| **更新後用戶端需重新設定** | ❌ 是 — 每台用戶端需重新匯入 | ✅ 不需要 | ✅ 不需要 | ✅ 不需要 | ✅ 不需要 — Root CA 持續受信任 |
| **設定複雜度** | 無（但警告預設仍存在） | 中等 | 中高 | 低–中 | 低 |
| **需要額外服務** | 無 | 無 | Cloudflare 帳號 + API Token | 無 | 無 |
| **主機名稱公開曝露** | ✅ 否 | ❌ 是（CT logs） | ❌ 是（CT logs） | ❌ 是 | ✅ 否 |
| **可在隔離 LAN 使用** | ✅ 是 | ❌ 否 | ❌ 否 | ❌ 否 | ✅ 是 |
| **多用戶端信任** | 每台用戶端手動，每次更新都要重做 | 自動 | 自動 | 自動 | 每台用戶端只需設定一次 |
| **費用** | 免費 | 免費 | 免費 | $100–300/年 | 免費 |
| **以 FQDN 存取** | ✅ 是（但仍顯示憑證警告，除非手動匯入 PVE Root CA） | ✅ 是 | ✅ 是 | ✅ 是 | ✅ 是 |
| **以 IP 存取** | ✅ 是（但仍顯示憑證警告） | ❌ 否 | ❌ 否 | ❌ 否 | ✅ 是（SAN 包含 IP） |
| **PVE Web UI 憑證管理** | ✅ 是（僅限伺服器端） | ✅ 是（僅限伺服器端） | ✅ 是（僅限伺服器端） | ❌ 手動 | ❌ 手動（本腳本） |

---

### 各方法適用情境

**PVE 預設自簽憑證**

開箱即用的憑證。上手最快，但預設會顯示瀏覽器警告。可透過在每台用戶端手動匯入憑證來消除警告，但每年憑證更新後需重新匯入。適合快速測試，不適合日常使用。

**ACME / Let's Encrypt (HTTP-01)**

內建於 Proxmox Web UI（Datacenter → pve → Certificates）。需要可公開存取的網域以及開放 port 80/443。不適用於 NAT 後方或離線網路的內部伺服器。

**Let's Encrypt + Cloudflare DNS-01**

透過 DNS API 驗證，不需開放 port 80/443。需要由 Cloudflare（或其他支援的 DNS 供應商）管理的公開網域及 API Token。主機名稱會出現在公開的 Certificate Transparency 日誌中。適合任何使用支援供應商管理公開網域的環境——無論是個人 homelab 或企業內網皆可，但須注意主機名稱將出現於公開 CT 日誌。

**商業萬用字元憑證**

涵蓋公開網域的所有子網域（`*.demo.local` 無效，需要真實的公開 TLD）。費用高且通常需手動更新。僅適合已有公開網域基礎架構的正式環境。

**本腳本 — 自簽 CA + 用戶端信任**

✅ 推薦用於任何無公開網域的內部基礎架構

產生私有 Root CA 及含有正確 SAN（DNS + IP）的節點憑證，並安裝至 PVE。每台用戶端只需執行一次對應的用戶端腳本，即可完成 CA 信任匯入。不需要公開網域、網際網路連線、port forwarding 或訂閱授權。

適合以下情境：
- 無公開網域的內部基礎架構，包含個人 homelab、中小企業或企業私有雲
- 離線或僅有 NAT 的網路環境
- 不希望主機名稱出現在公開 CT 日誌中
- 多個 PVE 節點各自需要受信任憑證
- 希望伺服器端與用戶端都能一鍵完成設定的使用者

主要取捨是每台新用戶端需執行一次用戶端腳本來匯入 CA。與直接匯入 PVE 預設憑證不同，Root CA 在更新時不會改變 — 因此用戶端永遠不需要重新匯入。

---

## 運作原理

```
┌─────────────────────────────────────────────────┐
│  Proxmox VE 伺服器                               │
│                                                 │
│  pve-cert.sh                                    │
│  ├── 自動偵測 IP / FQDN                          │
│  ├── 產生 Root CA  (pve-local-ca.crt/.key)      │
│  ├── 產生由 Root CA 簽署的節點憑證               │
│  ├── 安裝至 /etc/pve/local/                     │
│  └── 重啟 pveproxy / pvedaemon                  │
└────────────────┬────────────────────────────────┘
                 │  scp  pve-local-ca.crt
                 ▼
┌─────────────────────────────────────────────────┐
│  用戶端  ← 每台用戶端重複執行                     │
│                                                 │
│  pve-cert-windows.bat  /  pve-cert-linux.sh     │
│  pve-cert-macos.sh                              │
│  ├── 透過 scp 下載 CA 憑證                       │
│  ├── 透過 ssh hostname -f 自動偵測 FQDN          │
│  ├── 新增項目至 hosts 檔案                       │
│  └── 將 CA 憑證匯入系統信任存放區                 │
└─────────────────────────────────────────────────┘
                 │
                 ▼
     https://pve.demo.local:8006  🔒
```

---

## 需求環境

### Proxmox VE 伺服器
- 以 `root` 執行
- 已安裝 `openssl`（PVE 預設已包含）

### Windows 用戶端
- 以**系統管理員**執行
- 已啟用 OpenSSH Client（Windows 10 build 1809+）
  - 設定 → 應用程式 → 選用功能 → OpenSSH 用戶端
- 需先在 PVE 伺服器執行 `pve-cert.sh`

### Linux 用戶端（Ubuntu / Debian）
- 以 `sudo` 執行
- 已安裝 `openssh-client` 與 `openssl`
  - `sudo apt install openssh-client openssl`
- 已安裝 `ca-certificates` 套件
  - `sudo apt install ca-certificates`
- 已安裝 `libnss3-tools`（提供 `certutil`，用於 Firefox / Chrome NSS 存放區匯入）
  - `sudo apt install libnss3-tools`
  - 腳本若偵測到缺少此套件會自動安裝
- 需先在 PVE 伺服器執行 `pve-cert.sh`

### macOS 用戶端
- 以 `sudo` 執行
- `ssh`、`scp`、`openssl`、`security` 均為 macOS 內建，無需另行安裝
- 需先在 PVE 伺服器執行 `pve-cert.sh`

---

## 下載

在 PVE 伺服器及每台用戶端上 clone 此 repository：

**在 Proxmox VE（SSH）：**
```bash
git clone https://github.com/anomixer/pve-cert.git
cd pve-cert
```

**在 Windows（命令提示字元或 PowerShell）：**
```cmd
git clone https://github.com/anomixer/pve-cert.git
cd pve-cert
```

**在 Linux / macOS（終端機）：**
```bash
git clone https://github.com/anomixer/pve-cert.git
cd pve-cert
```

> 或直接[下載 ZIP 壓縮檔](https://github.com/anomixer/pve-cert/archive/refs/heads/main.zip)並解壓縮。

---

## 安裝步驟

### 步驟一 — 在 Proxmox VE 伺服器執行

```bash
sudo bash pve-cert.sh
```

腳本將會：
1. 自動偵測 PVE IP 與 FQDN（`hostname -f`）
2. 執行前向你確認資訊
3. 產生 `Proxmox VE Local Root CA` 及含有 DNS 名稱與 IP 位址 SAN 的節點憑證
4. 將現有憑證備份至 `/etc/pve/local/pveproxy-ssl.pem.bak.<timestamp>`
5. 安裝新憑證並重啟 `pveproxy` / `pvedaemon`
6. 印出完整憑證資訊及所有輸出檔案位置

**PVE 上的輸出檔案：**

| 檔案 | 說明 |
|------|------|
| `/root/pve-local-ca.crt` | Root CA 憑證（由用戶端腳本下載） |
| `/root/pve-local-ca.key` | Root CA 私鑰 — 留在伺服器，請勿分享 |
| `/root/pve-node.crt` | 節點憑證 |
| `/root/pve-node.key` | 節點私鑰 |
| `/etc/pve/local/pveproxy-ssl.pem` | PVE Web UI 使用的現行憑證 |
| `/etc/pve/local/pveproxy-ssl.key` | PVE Web UI 使用的現行私鑰 |

**多台 PVE 伺服器：** 若有多台 Proxmox VE 伺服器，請在每台上分別執行 `pve-cert.sh`。每台伺服器會各自產生獨立的 Root CA 與節點憑證。

---

### 步驟二 — 在每台用戶端執行

依作業系統執行對應腳本：

**Windows** — 右鍵點擊 `pve-cert-windows.bat` → 以系統管理員身分執行
```bat
pve-cert-windows.bat
```

**Linux（Ubuntu / Debian）**
```bash
sudo bash pve-cert-linux.sh
```

**macOS**
```bash
sudo bash pve-cert-macos.sh
```

三個腳本執行流程相同：
1. 詢問 PVE IP 位址與 SSH 使用者名稱
2. 透過 `scp` 從 PVE 下載 `pve-local-ca.crt`（提示輸入一次 SSH 密碼）
3. 透過 `ssh hostname -f` 自動偵測 PVE FQDN
4. 新增項目至系統 hosts 檔案
5. 將 CA 憑證匯入作業系統信任存放區
6. 可選：在預設瀏覽器開啟 PVE Web UI

**Linux 額外步驟：** 同時自動將 CA 憑證匯入 Chrome、Chromium 及 Firefox（包含 Ubuntu 21.10+ 以 snap 安裝的 Firefox）的 NSS 存放區，無需任何手動瀏覽器操作。

**多台用戶端：** 在每台需要存取 PVE Web UI 且不顯示憑證警告的機器上分別執行對應腳本。

**多個 PVE 節點：** 在同一台機器上針對每個 PVE 節點各執行一次用戶端腳本。腳本會累積網站項目而不覆蓋現有資料 — 每個網站以 IP、FQDN 及憑證指紋追蹤。

---

### 步驟三 — 開啟 Web UI

重啟瀏覽器，然後透過 FQDN 存取：

```
https://<your-pve-fqdn>:8006
```

或直接以 IP 位址存取：

```
https://<your-pve-ipaddr>:8006
```

兩種方式均可不顯示憑證警告 — 憑證 SAN 同時包含 FQDN 與 IP 位址。瀏覽器應顯示鎖頭 🔒。日常使用建議以 FQDN 存取（詳見[注意事項](#注意事項)）。

---

## 移除

### PVE 伺服器

```bash
sudo bash pve-cert.sh -u
```

- 自動找到最近的備份並還原
- 重啟 `pveproxy` / `pvedaemon`

### 用戶端

**Windows** — 以系統管理員身分執行：
```bat
pve-cert-windows.bat -u
```

**Linux：**
```bash
sudo bash pve-cert-linux.sh -u
```

**macOS：**
```bash
sudo bash pve-cert-macos.sh -u
```

三個腳本均會列出已登錄的網站清單：

```
  Registered PVE sites:
  -----------------------------------
    [1]  192.168.1.111  <>  pve1.demo.local
    [2]  192.168.1.112  <>  pve2.demo.local
    [0]  Remove ALL

  Select [1-2, 0=all]:
```

對每個選取的網站，腳本將會：
- 移除 hosts 項目
- 從作業系統信任存放區移除 CA 憑證（依指紋比對）
- 從瀏覽器 NSS 存放區移除 CA 憑證（Linux：Chrome/Chromium 及 Firefox，包含 snap 版）
- 刪除資料目錄中的本地憑證檔案

---

## 注意事項

### 用戶端腳本比較

| | **Windows** | **Linux** | **macOS** |
|---|---|---|---|
| **腳本** | `pve-cert-windows.bat` | `pve-cert-linux.sh` | `pve-cert-macos.sh` |
| **執行權限** | 系統管理員 | `sudo` | `sudo` |
| **Hosts 檔案** | `C:\Windows\System32\drivers\etc\hosts` | `/etc/hosts` | `/etc/hosts` |
| **信任存放區** | Windows Root CA 存放區（`certutil`） | 系統 CA bundle（`update-ca-certificates` / `update-ca-trust`）+ NSS 存放區（Chrome/Firefox） | macOS Keychain（`security`） |
| **憑證指紋** | SHA-1 thumbprint（PowerShell） | SHA-256（openssl） | SHA-1（openssl + Keychain） |
| **資料目錄** | `%ProgramData%\pve-cert\` | `~/.local/share/pve-cert/` | `~/Library/Application Support/pve-cert/` |
| **開啟瀏覽器** | `start` | `xdg-open` | `open` |
| **額外相依套件** | OpenSSH Client（Win10+ 內建） | `openssh-client`、`openssl`、`ca-certificates`、`libnss3-tools`（缺少時自動安裝） | 無（全部內建） |

---

### 為什麼用 FQDN 而不是 IP 位址？

瀏覽器使用憑證的 **Subject Alternative Name（SAN）** 欄位來驗證 TLS，而非僅依賴 Common Name（CN）。SAN 項目可以是 DNS 名稱或 IP 位址，但兩者被視為完全不同的識別子。

本腳本在憑證中**同時包含**兩者：

```
SAN: DNS:pve92.demo.local
     IP:192.168.21.92
```

因此 `https://192.168.21.92:8006` **可以**不顯示警告正常存取。不過強烈建議使用 FQDN，原因如下：

- **IP 位址可能改變。** 若 PVE 伺服器被分配到新 IP，憑證 SAN 就不再匹配，警告會再次出現。只要 `hosts` 項目或 DNS 記錄保持更新，FQDN 就能持續有效。
- **瀏覽器行為差異。** 部分瀏覽器（尤其是較舊版本的 Chrome/Edge）不接受私有 CA 憑證中的 IP SAN，仍會顯示警告。
- **一致性。** 使用 FQDN 讓書籤、API 呼叫及腳本在不同環境中都能通用，不需硬編碼 IP 位址。

用戶端腳本寫入的 `hosts` 項目會將 FQDN 對應到目前的 IP，即使沒有本地 DNS 伺服器，瀏覽器也能正確解析。

---

- **憑證 CN**：`Proxmox VE Local Root CA (<hostname>)`

- 所有持久性資料儲存於平台專屬目錄：
  - **Windows：** `%ProgramData%\pve-cert\`
  - **Linux：** `~/.local/share/pve-cert/`
  - **macOS：** `~/Library/Application Support/pve-cert/`
