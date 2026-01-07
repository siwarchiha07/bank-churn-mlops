from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import joblib
import numpy as np
from typing import List
import logging
import os

from app.models import CustomerFeatures, PredictionResponse, HealthResponse

# Configuration du logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialisation FastAPI
app = FastAPI(
    title="Bank Churn Prediction API",
    description="API de prediction de defaillance client",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc"
)

# CORS pour permettre les requetes depuis un navigateur
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Chargement du modele au demarrage
MODEL_PATH = os.getenv("MODEL_PATH", "model/churn_model.pkl")
model = None

@app.on_event("startup")
async def load_model():
    """Charge le modele au demarrage de l'API"""
    global model
    try:
        model = joblib.load(MODEL_PATH)
        logger.info(f"Modele charge avec succes depuis {MODEL_PATH}")
    except Exception as e:
        logger.error(f"Erreur lors du chargement du modele : {e}")
        model = None

@app.get("/", tags=["General"])
def root():
    """Endpoint racine"""
    return {
        "message": "Bank Churn Prediction API",
        "version": "1.0.0",
        "status": "running",
        "docs": "/docs"
    }

@app.get("/health", response_model=HealthResponse, tags=["General"])
def health_check():
    """Verification de l'etat de l'API"""
    if model is None:
        raise HTTPException(
            status_code=503, 
            detail="Modele non charge"
        )
    return {
        "status": "healthy",
        "model_loaded": True
    }

@app.post("/predict", response_model=PredictionResponse, tags=["Prediction"])
def predict(features: CustomerFeatures):
    """
    Predit si un client va partir (churn)
    
    Retourne :
    - churn_probability : probabilite de churn (0 a 1)
    - prediction : 0 (reste) ou 1 (part)
    - risk_level : Low, Medium ou High
    """
    if model is None:
        raise HTTPException(
            status_code=503, 
            detail="Modele non disponible"
        )
    
    try:
        # Preparation des features
        input_data = np.array([[
            features.CreditScore,
            features.Age,
            features.Tenure,
            features.Balance,
            features.NumOfProducts,
            features.HasCrCard,
            features.IsActiveMember,
            features.EstimatedSalary,
            features.Geography_Germany,
            features.Geography_Spain
        ]])
        
        # Prediction
        proba = model.predict_proba(input_data)[0, 1]
        prediction = int(proba > 0.5)
        
        # Classification du risque
        if proba < 0.3:
            risk = "Low"
        elif proba < 0.7:
            risk = "Medium"
        else:
            risk = "High"
        
        logger.info(
            f"Prediction effectuee : proba={proba:.4f}, "
            f"prediction={prediction}, risk={risk}"
        )
        
        return {
            "churn_probability": round(float(proba), 4),
            "prediction": prediction,
            "risk_level": risk
        }
    
    except Exception as e:
        logger.error(f"Erreur lors de la prediction : {e}")
        raise HTTPException(
            status_code=500, 
            detail=f"Erreur de prediction : {str(e)}"
        )

@app.post("/predict/batch", tags=["Prediction"])
def predict_batch(features_list: List[CustomerFeatures]):
    """
    Predictions en batch pour plusieurs clients
    """
    if model is None:
        raise HTTPException(status_code=503, detail="Modele non disponible")
    
    try:
        predictions = []
        
        for features in features_list:
            input_data = np.array([[
                features.CreditScore, features.Age, features.Tenure,
                features.Balance, features.NumOfProducts, features.HasCrCard,
                features.IsActiveMember, features.EstimatedSalary,
                features.Geography_Germany, features.Geography_Spain
            ]])
            
            proba = model.predict_proba(input_data)[0, 1]
            prediction = int(proba > 0.5)
            
            predictions.append({
                "churn_probability": round(float(proba), 4),
                "prediction": prediction
            })
        
        logger.info(f"Batch prediction : {len(predictions)} clients traites")
        
        return {"predictions": predictions, "count": len(predictions)}
    
    except Exception as e:
        logger.error(f"Erreur batch prediction : {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)