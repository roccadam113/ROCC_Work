import os
import base64
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage
from playwright.sync_api import sync_playwright

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="google/gemma-3-27b-it",
    temperature=0,
)


def vlm_read_website(url: str, title: str = "網頁內容") -> str:
    """
    使用 Playwright 滾動截圖，並使用多模態 LLM 讀取網頁內容。
    """
    print(f"📸 [VLM] 啟動視覺閱讀: {url}")

    def capture_rolling_screenshots(url, output_dir="scans_temp"):
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)
        screenshots_b64 = []

        try:
            with sync_playwright() as p:
                # 啟動瀏覽器（無頭模式）
                browser = p.chromium.launch(
                    headless=True,
                    args=[
                        "--disable-blink-features=AutomationControlled"
                    ],  # 規避部分反爬蟲
                )

                # 設定視窗大小（模擬桌面瀏覽）
                context = browser.new_context(viewport={"width": 1280, "height": 1200})
                page = context.new_page()

                # 前往網頁
                page.goto(url, wait_until="domcontentloaded", timeout=30000)
                page.wait_for_timeout(3000)  # 等待渲染

                # --- CSS 注入（去廣告/彈窗） ---
                page.add_style_tag(
                    content="""
                    iframe { opacity: 0 !important; pointer-events: none !important; }
                    div[id*='cookie'], div[class*='cookie'], div[id*='ads'], div[class*='ads'] { display: none !important; }
                    div[class*='overlay'], div[id*='overlay'], div[class*='popup'] { opacity: 0 !important; pointer-events: none !important; }
                    header, nav { position: absolute !important; } /* 防止置頂標頭遮擋截圖 */
                """
                )

                total_height = page.evaluate("document.body.scrollHeight")
                viewport_height = 1200
                current_scroll = 0

                for i in range(3):
                    # 滾動
                    page.evaluate(f"window.scrollTo(0, {current_scroll})")
                    page.wait_for_timeout(1000)  # 等待滾動後渲染

                # 截圖並轉為 Base64
                    b64 = base64.b64encode(page.screenshot()).decode("utf-8")
                    screenshots_b64.append(b64)
                    print(f"   - 截圖 {i+1} 完成 (捲動: {current_scroll})")

                    current_scroll += viewport_height - 200  # 重疊 200px 避免割裂文字
                    if current_scroll >= total_height:
                        break

                browser.close()
        except Exception as e:
            print(f"❌ 截圖失敗: {e}")

        return screenshots_b64

    # 執行截圖
    images = capture_rolling_screenshots(url)

    if not images:
        return "錯誤：無法讀取網頁內容或截圖失敗。"

    print(f"🤖 [LLM] 正在分析 {len(images)} 張圖片...")

    # --- 組裝多模態訊息 ---
    msg_content = [
        {
            "type": "text",
            "text": f"這是一個網頁的滾動截圖，標題為：{title}。\n請忽略廣告與導航欄，摘要此網頁的核心內容，並特別關注任何數據、日期或具體事實。",
        }
    ]

    # 加入所有圖片
    for img in images:
        msg_content.append(
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{img}"}}
        )

    # 呼叫 LLM
    try:
        response = llm.invoke([HumanMessage(content=msg_content)])
        return response.content
    except Exception as e:
        return f"LLM 分析失敗: {e}"


# # --- 3. 測試執行區 ---
# if __name__ == "__main__":
#     # 測試用網址 (範例：NVIDIA 新聞或任何技術部落格)
#     test_url = "https://www.nvidia.com/zh-tw/"
#     test_title = "NVIDIA 官方網站"

#     result = vlm_read_website(test_url, test_title)

#     print("\n" + "="*30)
#     print("📝 VLM 閱讀結果:")
#     print(result)
