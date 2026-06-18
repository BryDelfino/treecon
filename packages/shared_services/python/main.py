from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import simulation

app = FastAPI(title="Treecon Spatial Simulation API")

# Enable CORS for Flutter Web Local Host
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class IDWRequest(BaseModel):
    grid_resolution: float = 0.08
    power: float = 2.0

class CARequest(BaseModel):
    steps: int = 5
    grid_resolution: float = 0.08
    spread_factor: float = 0.08

import traceback
from fastapi import HTTPException

@app.get("/")
def read_root():
    return {"status": "running", "engine": "Treecon Spatial Engine"}

@app.post("/api/idw")
def get_idw(req: IDWRequest):
    try:
        result = simulation.run_idw(
            grid_resolution=req.grid_resolution,
            power=req.power
        )
        return result
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"IDW Error: {str(e)}")

@app.post("/api/forecast")
def get_forecast(req: CARequest):
    try:
        result = simulation.run_ca_simulation(
            steps=req.steps,
            grid_resolution=req.grid_resolution,
            spread_factor=req.spread_factor
        )
        return result
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"CA Error: {str(e)}")

@app.post("/api/kriging")
def get_kriging():
    try:
        result = simulation.run_kriging()
        return result
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Kriging Error: {str(e)}")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)

