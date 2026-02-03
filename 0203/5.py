from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import JsonOutputParser
from langchain_core.output_parsers import StrOutputParser

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="Qwen/Qwen3-VL-8B-Instruct",
)

prompt = ChatPromptTemplate.from_messages(
    [
        (
            "system",
            "你是專業文章編輯，將使用者提供的内容，歸納 3 個重點，并以繁體中文輸出。",
        ),
        ("human", "{article_content}"),
    ]
)

parser = StrOutputParser()

chain = prompt | llm | parser

article = """
在萬華區一間不起眼的鐘錶工作室裡，李師傅正戴著單眼放大鏡 (Loupe)，專注地檢視一只停擺已久的機械錶 (Mechanical Watch)。這只錶的潤滑油早已乾涸，且擒縱系統 (Escapement) 嚴重磨損。

一位焦急的年輕人站在櫃台前等待，李師傅沒有多餘的寒暄，只是冷靜地拆解機芯，並指著微小的游絲 (Balance Spring) 向年輕人解釋機械運作的邏輯：「這如同心臟的節律點，一旦受潮生鏽，時間就會死亡。」

經過三天不眠不休的精密調校 (Calibration)，齒輪終於重新咬合，發出清脆規律的聲響。交貨時，年輕人激動地想支付額外的費用，李師傅卻揮手拒絕，轉身繼續擦拭工具，淡淡地說道：「我修的是錶，不是你的焦慮。」

這或許就是專業 (Professionalism) 的極致表現。
"""
print("開始生成")
result = chain.invoke({"article_content": article})
print(result)
