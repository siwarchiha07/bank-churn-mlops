from pydantic import BaseModel, Field
from typing import List

class CustomerFeatures(BaseModel):
    """Schema pour les features d'un client"""
    CreditScore: int = Field(..., ge=300, le=850, description="Score de credit")
    Age: int = Field(..., ge=18, le=100, description="Age du client")
    Tenure: int = Field(..., ge=0, le=10, description="Anciennete en annees")
    Balance: float = Field(..., ge=0, description="Solde du compte")
    NumOfProducts: int = Field(..., ge=1, le=4, description="Nombre de produits")
    HasCrCard: int = Field(..., ge=0, le=1, description="Possession carte credit")
    IsActiveMember: int = Field(..., ge=0, le=1, description="Membre actif")
    EstimatedSalary: float = Field(..., ge=0, description="Salaire estime")
    Geography_Germany: int = Field(..., ge=0, le=1, description="Client allemand")
    Geography_Spain: int = Field(..., ge=0, le=1, description="Client espagnol")
    
    class Config:
        schema_extra = {
            "example": {
                "CreditScore": 650,
                "Age": 35,
                "Tenure": 5,
                "Balance": 50000,
                "NumOfProducts": 2,
                "HasCrCard": 1,
                "IsActiveMember": 1,
                "EstimatedSalary": 75000,
                "Geography_Germany": 0,
                "Geography_Spain": 1
            }
        }

class PredictionResponse(BaseModel):
    """Schema pour la reponse de prediction"""
    churn_probability: float = Field(..., description="Probabilite de churn (0-1)")
    prediction: int = Field(..., description="Prediction binaire (0=reste, 1=part)")
    risk_level: str = Field(..., description="Niveau de risque (Low/Medium/High)")

class HealthResponse(BaseModel):
    """Schema pour le health check"""
    status: str
    model_loaded: bool