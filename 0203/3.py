from openai import OpenAI
import json

client = OpenAI(base_url="https://ws-02.wade0426.me/v1", api_key="")

history = [{"role": "system", "content": "你是一個繁體中文聊天機器人，會簡易回答"}]

while True:
    user_input = input("Input: ")
    if user_input.lower() in ["q", "exit"]:
        print("end")
        break
    history.append({"role": "user", "content": user_input})
    try:
        response = client.chat.completions.create(
            model="Qwen/Qwen3-VL-8B-Instruct",
            messages=history,
            temperature=0.7,
            max_tokens=256,
        )
        full_reply = response.choices[0].message.content
        print(f"AI: {full_reply}")
        history.append({"role": "assistant", "content": full_reply})
    except Exception as e:
        print(e)
