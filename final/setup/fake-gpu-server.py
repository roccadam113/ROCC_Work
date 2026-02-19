from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

util_value = 10  # default

def prometheus_metrics() -> str:
    # 這裡是假的 GPU 指標：用 util_value 推一組可用於展示的數值
    util = float(util_value)

    # 假設最大顯存 24576 MiB（24GB），用 util 估算使用量
    mem_used_mib = 24576.0 * (util / 100.0)

    # 假設最大功耗 300W，用 util 估算功耗
    power_watts = 300.0 * (util / 100.0)

    lines = []
    lines.append("# HELP fake_gpu_utilization_percent Fake GPU utilization percentage (0-100).")
    lines.append("# TYPE fake_gpu_utilization_percent gauge")
    lines.append(f"fake_gpu_utilization_percent {util:.2f}")

    lines.append("# HELP fake_gpu_memory_used_megabytes Fake GPU memory used in MiB.")
    lines.append("# TYPE fake_gpu_memory_used_megabytes gauge")
    lines.append(f"fake_gpu_memory_used_megabytes {mem_used_mib:.2f}")

    lines.append("# HELP fake_gpu_power_watts Fake GPU power draw in watts.")
    lines.append("# TYPE fake_gpu_power_watts gauge")
    lines.append(f"fake_gpu_power_watts {power_watts:.2f}")

    return "\n".join(lines) + "\n"


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))

    def do_GET(self):
        global util_value
        u = urlparse(self.path)

        if u.path == "/healthz":
            return self._send(200, "ok\n")

        if u.path == "/gpu_util":
            return self._send(200, f"{util_value}\n")

        if u.path == "/set":
            qs = parse_qs(u.query or "")
            if "util" not in qs:
                return self._send(400, "missing util\n")
            try:
                util_value = int(qs["util"][0])
            except Exception:
                return self._send(400, "bad util\n")
            return self._send(200, f"ok util={util_value}\n")

        if u.path == "/metrics":
            return self._send(200, prometheus_metrics(), "text/plain; version=0.0.4; charset=utf-8")

        return self._send(404, "not found\n")


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), H).serve_forever()
