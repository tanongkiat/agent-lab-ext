# file: C:\lab\agent-lab-ext\services\subscription-service\app.py
"""subscription-service (lab): plan catalog + billing webhook -> LiteLLM admin API."""
import os
import httpx
from fastapi import FastAPI, Header, HTTPException

L = os.environ["LITELLM_URL"]
H = {"Authorization": f"Bearer {os.environ['SUB_ADMIN_KEY']}"}
SECRET = os.environ.get("WEBHOOK_SECRET", "lab-secret")

# plan catalog = source of truth (ห้ามแก้ budget/team ใน LiteLLM UI ตรง)
PLANS = {
    "free":      {"kind": "end_user", "budget_id": "plan-free"},
    "pro":       {"kind": "end_user", "budget_id": "plan-pro"},
    "dev-basic": {"kind": "developer", "team_id": "team-dev-basic", "budget": 0.05, "mcp": ["expert_solution"]},
    "dev-pro":   {"kind": "developer", "team_id": "team-dev-pro", "budget": 1, "mcp": ["expert_solution"]},
}
DEV_TEAMS = [p["team_id"] for p in PLANS.values() if p["kind"] == "developer"]
app = FastAPI(title="subscription-service")


def post(path: str, body: dict) -> httpx.Response:
    return httpx.post(f"{L}{path}", headers=H, json=body, timeout=30)


def end_user(user: str, plan: dict, active: bool) -> dict:
    if not active:
        post("/customer/block", {"user_ids": [user]})
        return {"action": "customer blocked"}
    post("/customer/unblock", {"user_ids": [user]})
    r = post("/customer/update", {"user_id": user, "budget_id": plan["budget_id"]})
    if r.status_code >= 400:
        r = post("/customer/new", {"user_id": user, "budget_id": plan["budget_id"]})
    r.raise_for_status()
    return {"action": f"customer -> {plan['budget_id']}"}


def developer(user: str, name: str, plan: dict, active: bool) -> dict:
    keys = httpx.get(f"{L}/key/list", headers=H, params={"user_id": user}, timeout=30).json().get("keys", [])
    for k in keys:  # ปิด key เดิมทุกครั้งที่เปลี่ยน plan หรือยกเลิก
        post("/key/block", {"key": k})
    if not active:
        return {"action": "developer keys blocked", "blocked": len(keys)}
    post("/user/new", {"user_id": user, "user_role": "internal_user"})  # มีอยู่แล้วก็ไม่เป็นไร
    for t in DEV_TEAMS:
        if t != plan["team_id"]:
            post("/team/member_delete", {"team_id": t, "user_id": user})
    post("/team/member_add", {"team_id": plan["team_id"], "member": {"user_id": user, "role": "user"},
                              "max_budget_in_team": plan["budget"]})
    r = post("/key/generate", {"key_alias": f"dev-{user}-{name}", "team_id": plan["team_id"], "user_id": user,
                               "object_permission": {"mcp_servers": plan["mcp"]}})
    r.raise_for_status()
    return {"action": f"developer -> {plan['team_id']}", "key": r.json()["key"]}  # lab: ส่ง key กลับให้ทดสอบ


@app.post("/webhook/billing")
def billing_webhook(ev: dict, x_webhook_secret: str = Header("")):
    if x_webhook_secret != SECRET:
        raise HTTPException(401, "bad webhook secret")
    plan = PLANS.get(ev.get("plan", ""))
    if not plan:
        raise HTTPException(400, f"unknown plan: {ev.get('plan')}")
    active = ev.get("status", "active") == "active"
    user = ev["user_id"]
    if plan["kind"] == "end_user":
        return {"user": user, **end_user(user, plan, active)}
    return {"user": user, **developer(user, ev["plan"], plan, active)}


@app.get("/plans")
def plans():
    return PLANS