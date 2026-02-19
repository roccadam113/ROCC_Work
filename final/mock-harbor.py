from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Dict, Any, List

app = FastAPI(title="mock-harbor")

projects: Dict[str, Dict[str, Any]] = {}
next_id = 1

class CreateProjectReq(BaseModel):
    project_name: str
    public: bool = False

@app.get("/api/v2.0/health")
def health():
    return {"status": "healthy"}

@app.post("/api/v2.0/projects", status_code=201)
def create_project(req: CreateProjectReq):
    global next_id
    if req.project_name in projects:
        raise HTTPException(status_code=409, detail="project already exists")
    projects[req.project_name] = {
        "project_id": next_id,
        "name": req.project_name,
        "public": req.public,
    }
    next_id += 1
    return {"created": True}

@app.get("/api/v2.0/projects")
def list_projects(name: str | None = None) -> List[Dict[str, Any]]:
    if name:
        return [p for k, p in projects.items() if k == name]
    return list(projects.values())
