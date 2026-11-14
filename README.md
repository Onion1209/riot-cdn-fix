# riot-cdn-fix

Riot Client（英雄聯盟 / 聯盟戰棋）下載很慢時，把下載釘到最快的 Riot CDN 節點。

## 發現：Riot 下載走兩個網域，只改一個沒有用

網路上「Riot 下載慢 → 改 hosts 換節點」的做法，通常只改 `lol.secure.dyn.riotcdn.net`。改完 manifest（檔案清單）會變快，**但遊戲檔本體仍然很慢**。原因是兩者走不同網域：

| 內容 | 網域 |
|---|---|
| 清單 / manifest | `lol.secure.dyn.riotcdn.net` |
| 遊戲檔 bundle（真正的下載量） | `lol.dyn.riotcdn.net`（沒有 `secure`） |

bundle 的網域寫在 patchline 設定的 `bundles_url`，可以自己查：

```
https://clientconfig.rpg.riotgames.com/api/v1/config/public?namespace=keystone.products.league_of_legends.patchlines
```

裡面的 `"bundles_url": "https://lol.dyn.riotcdn.net/channels/public/bundles"` 就是遊戲檔的來源（2026-11 確認仍是如此）。

**兩個網域都要釘到同一個節點**，下載才會真的換線。實測（台灣、行動熱點）：

| 狀況 | bundle 下載速度 |
|---|---|
| 只釘 `secure` 網域，bundle 仍走 CloudFront | ~0.04 MB/s |
| 兩個網域都釘到快的節點 | ~7 MB/s |

## 其他觀察

- **冷熱快取差很多**：同一個節點，檔案不在快取（cache miss）時首位元組約 1.5 秒、約 1.5 MB/s；在快取時約 7 MB/s。對 bundle 發一個 1 byte 的 range 請求，就會把整個 bundle 拉進節點快取。
- **測速要用真的 bundle**：manifest 通常常駐快取，拿它測會讓每個節點看起來都很快。
- **改完 hosts 要讓 Riot 重新連線**：Riot 會沿用舊的 keep-alive 連線，在 Riot Client 按「暫停」再「繼續」（或重開）才會換到新節點。
- **怎麼確認有沒有生效**：看 `RiotClientServices` 的 443 連線連到哪個 IP，是不是你釘的節點，還是 CloudFront 的 IP。
- 其他 Riot 網域（例如 `valorant.secure.dyn.riotcdn.net`）有時會被 DNS 分到不同節點，可以拿來當候選節點。

## 腳本用法

`riot_cdn_fix.ps1`（Windows PowerShell）：

```powershell
.\riot_cdn_fix.ps1 -TestOnly   # 只測速，不改 hosts（不需系統管理員）
.\riot_cdn_fix.ps1             # 測速並把最快節點寫進 hosts（需系統管理員）
.\riot_cdn_fix.ps1 -Remove     # 移除腳本寫入的 hosts 設定
```

- 候選節點來自多個公共 DNS 的查詢結果，加上曾經測到很快的節點與上次選中的節點（存在 `last_best.txt`）。
- 用 `curl --resolve` 強制連到各節點測速，憑證驗證失敗或回應不是 200 的節點一律淘汰。
- 寫入的設定包在 `# RIOT-CDN-FIX BEGIN/END` 之間，`-Remove` 會整段移除。
- **更新完記得 `-Remove`**：Riot 之後換節點時，留著舊的 hosts 會讓更新失敗。

## 已知限制

- 腳本目前用**本機的 manifest** 當測速檔，依上面「測速要用真的 bundle」的觀察，測出來的速度可能偏樂觀。
- 內建的快節點 IP（`175.99.116.x`）是在台灣測到的，其他地區不一定適用，要以測速結果為準。
- 只處理英雄聯盟和聯盟戰棋。

## 注意

這是非官方做法，修改的是系統 hosts 檔。Riot 隨時可能調整 CDN，使用前請先用 `-TestOnly` 確認。
