from HW.tools.search_searxng import search_searxng as ss
from HW.tools.vlm_read_website import vlm_read_website as vlmrweb
from langchain_core.tools import tool
from langchain_core.messages import BaseMessage, HumanMessage, ToolMessage
from langchain_openai import ChatOpenAI
from typing import Annotated, TypedDict, Literal
from langgraph.graph import StateGraph, END, add_messages
from langgraph.prebuilt import ToolNode


class State(TypedDict):
    message: Annotated[list[BaseMessage], add_messages]


def check_cache():
    pass


def planner():
    pass


def final_answer():
    pass


def query_gen():
    pass


def search_tool():
    pass


def cache_router():
    pass


def planner_router():
    pass


flow = StateGraph(State)
flow.add_node("check_cache", check_cache)
flow.add_node("planner", planner)
flow.add_node("final_answer", final_answer)
flow.add_node("query_gen", query_gen)
flow.add_node("search_tool", search_tool)
flow.set_entry_point("check_cache")
flow.add_conditional_edges(
    "check_cache",
    cache_router,
    {
        "planner": "planner",
        END: END,
    },
)
flow.add_conditional_edges(
    "planner",
    planner_router,
    {
        "query_gen": "query_gen",
        "final_answer": "final_answer",
    },
)
flow.add_edge("query_gen", "search_tool")
flow.add_edge("search_tool", "planner")
flow.add_edge("final_answer", END)

app = flow.compile()
print(app.get_graph().draw_ascii())
