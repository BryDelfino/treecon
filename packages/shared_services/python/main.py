from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import pandas as pd
import io
import traceback
import requests
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

class CARequest(BaseModel):
    dataset_url: str
    steps: int = 5
    grid_resolution: float = 0.08
    spread_factor: float = 0.08

class KrigingRequest(BaseModel):
    dataset_url: str

@app.get("/")
def read_root():
    return {"status": "running", "engine": "Treecon Spatial Engine"}

@app.post("/api/forecast")
def get_forecast(req: CARequest):
    try:
        # Download the CSV
        response = requests.get(req.dataset_url)
        if response.status_code != 200:
            raise HTTPException(status_code=400, detail="Failed to download dataset")
        df = pd.read_csv(io.StringIO(response.text))
        # Drop rows missing critical values that would crash the simulation math
        df = df.dropna(subset=['latitude', 'longitude', 'GSI'])
        
        result = simulation.run_ca_simulation(
            df=df,
            steps=req.steps,
            grid_resolution=req.grid_resolution,
            spread_factor=req.spread_factor
        )
        return result
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"CA Error: {str(e)}")

@app.post("/api/kriging")
def get_kriging(req: KrigingRequest):
    try:
        response = requests.get(req.dataset_url)
        if response.status_code != 200:
            raise HTTPException(status_code=400, detail="Failed to download dataset")
        df = pd.read_csv(io.StringIO(response.text))
        # Drop rows missing critical values that would crash Kriging math
        df = df.dropna(subset=['latitude', 'longitude', 'GSI'])
        
        result = simulation.run_kriging(df=df)
        return result
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Kriging Error: {str(e)}")

@app.post("/api/datasets/process")
async def process_dataset(file: UploadFile = File(...)):
    if not file.filename.endswith(".csv"):
        raise HTTPException(status_code=400, detail="File must be a CSV")

    content = await file.read()
    
    # 5MB limit
    if len(content) > 5 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="File size exceeds 5MB limit")
        
    try:
        df = pd.read_csv(io.BytesIO(content))
    except Exception as e:
        raise HTTPException(status_code=400, detail="Invalid CSV format")
        
    required_cols = {'record_id', 'region', 'plantation', 'plot', 'GRI', 'GSI', 'longitude', 'latitude'}
    if not required_cols.issubset(set(df.columns)):
        missing = required_cols - set(df.columns)
        raise HTTPException(status_code=400, detail=f"Missing required columns: {missing}")
        
    def classify_gsi(val):
        if pd.isna(val): return 'Unknown'
        if val == 0: return 'Healthy'
        if val <= 10: return 'Low'
        if val <= 25: return 'Moderate'
        if val <= 60: return 'High'
        return 'Critical'
        
    df['severity_class'] = df['GSI'].apply(classify_gsi)

    csv = df.to_csv(index=False)

    return {
        "csv": csv
    }

@app.get("/api/plantations")
def get_plantations(dataset_url: str):
    import pandas as pd
    try:
        response = requests.get(dataset_url)
        if response.status_code != 200:
            raise HTTPException(status_code=400, detail="Failed to download dataset")
        df = pd.read_csv(io.StringIO(response.text))
        df = df.fillna("")
        return df.to_dict(orient="records")
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Plantations Error: {str(e)}")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

