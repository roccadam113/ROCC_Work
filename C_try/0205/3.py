from langchain_core.tools import tool
from langchain_core.messages import BaseMessage, HumanMessage, ToolMessage, AIMessage
from langchain_openai import ChatOpenAI
from typing import Annotated, TypedDict, Literal
from langgraph.graph import StateGraph, END, add_messages
from langgraph.prebuilt import ToolNode
import json

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="google/gemma-3-27b-it",
    temperature=0,
)


class AngentState(TypedDict):
    message: Annotated[list[BaseMessage], add_messages]


VIP_LIST = ["AIG", "ROCC"]


@tool
def extract_order_data(
    name: str, phone: str, product: str, quantity: int, address: str
):
    """
    資料提取專業工具
    專門用於從非結構化的文本中提取訂單相關資訊(姓名、電話、商品、數量、地址)
    """

    return {
        "name": name,
        "phone": phone,
        "product": product,
        "quantity": quantity,
        "address": address,
    }


with_tools = llm.bind_tools([extract_order_data])
tool_node = ToolNode([extract_order_data])


def agent_node(state: AngentState):
    response = with_tools.invoke(state["message"])
    return response


def human_review_node(state: AngentState):
    print("\n" + "=" * 30)
    print("偵測到VIP")
    print("=" * 30)

    last_msg = state["message"][-1]
    print(f"待審資料： {last_msg.content}")
    review = input("輸入OK表示通過，其餘拒絕")
    if review.lower() == "ok":
        return {
            "messages": [
                AIMessage(content="已收到訂單資料，偵測到VIP，切換人工審核"),
                HumanMessage(content="審核通過，請繼續後續動作。"),
            ]
        }
    else:
        return {
            "messages": [
                AIMessage(content="已收到訂單資料，切換人工審核"),
                HumanMessage(content="審核拒絕，取消交易並通知用戶。"),
            ]
        }


def router(state: AngentState):
    last_msg = state["message"][-1]
    if last_msg.tool_calls:
        return "tools"
    return END


def post_tool_router(state: AngentState) -> Literal["human_review", "agent"]:
    meassage = state["message"][-1]
    if isinstance(meassage, ToolMessage):
        try:
            data = json.loads(meassage.content)
            user_name = data.get("name", "")

            if user_name in VIP_LIST:
                print(f"Debug: 發現 VIP [{user_name}] -> 切換人工審核")
                return "human_review"

        except Exception as e:
            print(f"JSON 解析異常 ： {e}")
    return "agent"


workflow = StateGraph(AngentState)
workflow.add_node("agent", agent_node)
workflow.add_node("tools", tool_node)
workflow.add_node("human_review", human_review_node)

workflow.set_entry_point("agent")

workflow.add_conditional_edges("agent", router, {"tools": "tools", END: END})
workflow.add_conditional_edges(
    "tools", post_tool_router, {"human_review": "human_review", "agent": "agent"}
)

workflow.add_edge("human_review", "agent")

app = workflow.compile()
print(app.get_graph().draw_ascii())

print(VIP_LIST)
while True:
    user_inputs = input("Input : ")
    if user_inputs.lower() == "q":
        break
    for e in app.stream({"message": [HumanMessage(content=user_inputs)]}):
        for k, v in e.items():
            match (k):
                case "agent":
                    msg = v["messages"][-1]
                    if not msg.tool_calls:
                        print(msg.content)
                case "human_review":
                    print("審核完成")
