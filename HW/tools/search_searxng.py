import requests
import json

SEARXNG_URL = "https://puli-8080.huannago.com/search"

# --- 2. 核心搜尋函數 ---


def search_searxng(query: str, time_range: str = None, limit: int = 3):
    """
    執行 SearXNG 搜尋並返回結構化結果。

    參數:
        query (str): 搜尋關鍵字
        time_range (str, optional): 時間範圍 ('day', 'week', 'month', 'year')，預設為 None。
        limit (int, optional): 返回結果數量限制，預設為 3。

    回傳:
        list: 搜尋結果列表（字典格式）
    """
    print(f"🔍 正在搜尋: {query} (範圍: {time_range if time_range else '全部'})")

    # 建構請求參數
    params = {
        "q": query,
        "format": "json",
        "language": "zh-TW",  # 設定預設語言為繁體中文
    }

    if time_range and time_range != "all":
        params["time_range"] = time_range

    try:
        # 發送請求
        response = requests.get(SEARXNG_URL, params=params, timeout=10)
        response.raise_for_status()  # 檢查 HTTP 狀態碼

        data = response.json()
        results = data.get("results", [])

        # 簡單過濾：排除沒有 URL 的結果
        valid_results = [r for r in results if "url" in r]

        return valid_results[:limit]

    except requests.exceptions.RequestException as e:
        print(f"❌ 連線錯誤: {e}")
        return []
    except json.JSONDecodeError:
        print("❌ 解析 JSON 失敗，可能是回傳格式錯誤")
        return []
    except Exception as e:
        print(f"❌ 發生未預期錯誤: {e}")
        return []


# # --- 3. 測試執行區 ---
# if __name__ == "__main__":
#     # 測試關鍵字
#     test_query = "台積電最新股價新聞"

#     # 執行搜尋 (測試 time_range='day' 以獲取最新資訊)
#     results = search_searxng(test_query, time_range="day", limit=3)

#     print("\n" + "="*30)
#     print(f"📊 搜尋結果 ({len(results)} 筆):")

#     if results:
#         for idx, item in enumerate(results, 1):
#             print(f"\n[{idx}] {item.get('title', '無標題')}")
#             print(f"    🔗 連結: {item.get('url', '無連結')}")
#             # 顯示部分摘要，去除過多空白
#             snippet = item.get('content', '無摘要').strip().replace('\n', ' ')[:100]
#             print(f"    📝 摘要: {snippet}...")
#     else:
#         print("沒有找到相關結果，請檢查關鍵字或伺服器連線。")
