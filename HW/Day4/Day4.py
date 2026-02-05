from HW.tools.search_searxng import search_searxng as ss
from HW.tools.vlm_read_website import vlm_read_website as vlmrweb
from langchain_core.tools import tool
from langchain_core.messages import BaseMessage, HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from typing import Annotated, TypedDict, Literal
from langgraph.graph import StateGraph, END, add_messages
from langgraph.prebuilt import ToolNode
import json
import os

JSON_PATH = "HW/Day4.json"

llm = ChatOpenAI(
    base_url="https://ws-02.wade0426.me/v1",
    api_key="",
    model="google/gemma-3-27b-it",
    temperature=0,
)


class State(TypedDict):
    message: Annotated[list[BaseMessage], add_messages]
    query: str
    search_query: str
    time_range: str
    url: str
    title: str
    json_path: str
    cache_key: str
    cache_answer: str
    cache_hit: bool
    info_enough: bool
    planner_reason: str
    missing_reason: str
    used_strategies: list[str]
    last_query: str
    store_ok: bool
    value_reason: str
    iteration: int
    max_iterations: int
    max_reached: bool


def check_cache(state: State):
    print("\n[DEBUG] stage=check_cache")
    key = (state.get("cache_key") or "").strip()
    if not key:
        prompt = [
            SystemMessage(
                content=(
                    "你是快取索引器。"
                    "請把使用者問題濃縮成一個可用來查快取的索引詞。"
                    "規則："
                    "1 盡量用英文小寫關鍵字，空白分隔"
                    "2 6 到 12 個詞以內"
                    "3 不要輸出解釋，只輸出 JSON"
                    '輸出格式：{"key":"..."}'
                )
            ),
            HumanMessage(content=state.get("query", "")),
        ]

        msg = llm.invoke(prompt)
        text = (msg.content or "").strip()
        try:
            key = (json.loads(text).get("key") or "").strip()
        except Exception:
            key = ""

    path = state.get("json_path")
    if not path or not key:
        return {"cache_hit": False, "cache_key": key}
    if not os.path.exists(path):
        return {"cache_hit": False, "cache_key": key}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        # 支援兩種格式：
        # 1) {"items": {"key": "..."}}
        # 2) {"key": "..."}
        items = data.get("items") if isinstance(data, dict) else None
        if items is None and isinstance(data, dict):
            items = data
        if not isinstance(items, dict):
            return {"cache_hit": False, "cache_key": key}

        value = items.get(key)
        if not value:
            return {"cache_hit": False, "cache_key": key}

        if isinstance(value, dict):
            cached_answer = value.get("answer")
            cached_title = value.get("title")
            cached_url = value.get("url")
        else:
            cached_answer = value
            cached_title = None
            cached_url = None

        if not cached_answer:
            return {"cache_hit": False, "cache_key": key}

        return {
            "cache_hit": True,
            "cache_key": key,
            "cache_answer": cached_answer,
            "title": cached_title,
            "url": cached_url,
        }
    except Exception:
        return {"cache_hit": False, "cache_key": key}


def planner(state: State):
    print("\n[DEBUG] stage=planner")
    context = {
        "query": state.get("query", ""),
        "cache_answer": state.get("cache_answer", ""),
        "title": state.get("title", ""),
        "url": state.get("url", ""),
    }

    max_iterations = state.get("max_iterations", 10)
    iteration = state.get("iteration", 0)
    if iteration >= max_iterations:
        return {
            "info_enough": True,
            "planner_reason": "已達最大搜尋次數",
            "store_ok": False,
            "value_reason": "已達最大搜尋次數",
            "max_reached": True,
        }

    if not context["cache_answer"] and not context["url"]:
        return {
            "info_enough": False,
            "planner_reason": "目前沒有可用資訊",
            "store_ok": False,
            "value_reason": "沒有可用資訊可評估價值",
        }

    prompt = [
        SystemMessage(
            content=(
                "你是資料充足性判斷器。"
                "請判斷目前資料是否足夠回答使用者問題。"
                "如果不足，代表還需要去搜尋或呼叫工具。"
                "同時評估此資料是否有價值，值得寫入 knowledge_base。"
                "只輸出 JSON，不要輸出解釋文字。"
                '輸出格式：{"enough":true,"reason":"...","store_ok":true,"value_reason":"..."}'
            )
        ),
        HumanMessage(content=json.dumps(context, ensure_ascii=False)),
    ]

    msg = llm.invoke(prompt)
    text = (msg.content or "").strip()
    try:
        payload = json.loads(text)
        enough = bool(payload.get("enough"))
        reason = (payload.get("reason") or "").strip()
        store_ok = bool(payload.get("store_ok"))
        value_reason = (payload.get("value_reason") or "").strip()
    except Exception:
        enough = False
        reason = ""
        store_ok = False
        value_reason = ""

    return {
        "info_enough": enough,
        "planner_reason": reason,
        "store_ok": store_ok,
        "value_reason": value_reason,
    }


def final_answer(state: State):
    print("\n[DEBUG] stage=final_answer")
    context = {
        "query": state.get("query", ""),
        "info": state.get("cache_answer", ""),
        "title": state.get("title", ""),
        "url": state.get("url", ""),
        "from_cache": bool(state.get("cache_hit")),
    }

    if not context["info"]:
        if state.get("max_reached"):
            return {"cache_answer": "已達最大搜尋次數，仍無足夠資料可以回答。"}
        return {"cache_answer": "目前沒有足夠資料可以回答。"}

    prompt = [
        SystemMessage(
            content=(
                "你是回答生成器。"
                "請根據提供的資訊回答使用者問題。"
                "只根據資訊作答，不要編造。"
                "若資訊不足，請明確說明不足之處。"
                "from_cache 代表資訊是否來自快取，可用於調整語氣，但不要提到該欄位。"
            )
        ),
        HumanMessage(content=json.dumps(context, ensure_ascii=False)),
    ]
    msg = llm.invoke(prompt)
    answer = (msg.content or "").strip()

    if (
        state.get("store_ok")
        and state.get("json_path")
        and state.get("cache_key")
        and state.get("cache_answer")
    ):
        path = state["json_path"]
        key = state["cache_key"]
        value = {
            "answer": state.get("cache_answer"),
            "title": state.get("title"),
            "url": state.get("url"),
        }

        data = {}
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception:
                data = {}

        if not isinstance(data, dict):
            data = {}

        if isinstance(data.get("items"), dict):
            items = data["items"]
        else:
            items = data
            data = {"items": items}

        items[key] = value
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    return {"cache_answer": answer}


def query_gen(state: State):
    print("\n[DEBUG] stage=query_gen")
    used = state.get("used_strategies") or []
    context = {
        "query": state.get("query", ""),
        "missing_reason": state.get("planner_reason", ""),
        "used_strategies": used,
        "last_query": state.get("last_query", ""),
    }

    prompt = [
        SystemMessage(
            content=(
                "你是搜尋查詢產生器。"
                "請根據使用者問題與缺少原因，產生新的搜尋查詢。"
                "避免重複已用過的策略。"
                "策略範例：同義詞、英文化、加時間範圍、加地點、加數值/單位。"
                "只輸出 JSON，不要輸出解釋文字。"
                '輸出格式：{"query":"...","strategy":"...","missing_reason":"..."}'
            )
        ),
        HumanMessage(content=json.dumps(context, ensure_ascii=False)),
    ]

    msg = llm.invoke(prompt)
    text = (msg.content or "").strip()
    try:
        payload = json.loads(text)
        q = (payload.get("query") or "").strip()
        strategy = (payload.get("strategy") or "").strip()
        missing_reason = (payload.get("missing_reason") or "").strip()
    except Exception:
        q = ""
        strategy = ""
        missing_reason = ""

    new_used = used[:]
    if strategy and strategy not in new_used:
        new_used.append(strategy)

    return {
        "search_query": q,
        "last_query": q,
        "missing_reason": missing_reason,
        "used_strategies": new_used,
    }


def search_tool(state: State):
    print("\n[DEBUG] stage=search_tool")
    query = state.get("search_query") or state.get("query", "")
    iteration = state.get("iteration", 0) + 1
    if not query:
        return {"cache_answer": "", "title": "", "url": "", "iteration": iteration}

    time_range = state.get("time_range")
    results = ss(query, time_range=time_range, limit=3)
    if not results:
        return {"cache_answer": "", "title": "", "url": "", "iteration": iteration}

    top = results[0]
    title = top.get("title", "")
    url = top.get("url", "")
    snippet = (top.get("content") or "").strip()

    if url:
        content = vlmrweb(url, title or "網頁內容")
    else:
        content = snippet

    return {
        "cache_answer": content,
        "title": title,
        "url": url,
        "iteration": iteration,
    }


def cache_router(state: State) -> Literal["planner", "final_answer"]:
    print(f"[DEBUG] stage=cache_router cache_hit={state.get('cache_hit')}")
    if state.get("cache_hit"):
        return "final_answer"
    return "planner"


def planner_router(state: State) -> Literal["query_gen", "final_answer"]:
    print(f"[DEBUG] stage=planner_router info_enough={state.get('info_enough')}")
    if state.get("info_enough"):
        return "final_answer"
    return "query_gen"


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
        "final_answer": "final_answer",
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

while True:
    user_inputs = input("Input : ")
    if user_inputs.lower() == "q":
        break
    if not user_inputs.strip():
        print("請輸入問題，或輸入 q 退出。")
        continue

    state = {
        "query": user_inputs.strip(),
        "json_path": JSON_PATH,
        "used_strategies": [],
        "iteration": 0,
        "max_iterations": 10,
        "cache_key": "",
        "cache_hit": False,
        "cache_answer": "",
        "search_query": "",
        "time_range": "all",
    }

    result = app.invoke(state)
    answer = result.get("cache_answer", "")
    print("\n===== Answer =====")
    print(answer if answer else "沒有產生回答")
    print("==================\n")
