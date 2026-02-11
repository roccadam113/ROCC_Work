from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
import json

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="google/gemma-3-27b-it",
    temperature=0,
)


@tool
def extract_order_data(
    name: str, phone: str, product: str, quantity: int, address: str
):
    """
    資料提取專用工具。
    專門用於從非結構化文本中提取訂單相關資訊（姓名、電話、商品、數量、地址）。
    """

    return {
        "name": name,
        "phone": phone,
        "product": product,
        "quantity": quantity,
        "address": address,
    }


llm_with_tools = llm.bind_tools([extract_order_data])
user_input = "我是ROCC，電話123-456-789，我買了兩台電視到臺中。"

prompt = ChatPromptTemplate.from_messages(
    [
        ("system", "你是一個精準的訂單管理員，請從對話中提取訂單資訊。"),
        ("user", "{text}"),
    ]
)


def extract_args(ai_respose):
    if ai_respose.tool_calls:
        return ai_respose.tool_calls[0]["args"]
    return None


chain = prompt | llm_with_tools | extract_args

try:
    result = chain.invoke(
        {
            "text": user_input,
        }
    )

    if result:
        print(json.dumps(result, ensure_ascii=False, indent=2))

except Exception as e:
    print(e)
