from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from typing import List
import joblib
import numpy as np
import logging
import os
import json
import glob
import traceback
from pathlib import Path

from opencensus.ext.azure.log_exporter import AzureLogHandler

from app.models import CustomerFeatures, PredictionResponse, HealthResponse
from app.drift_detect import detect_drift


# ============================================================
# LOGGING & APPLICATION INSIGHTS
# ============================================================

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("bank-churn-api")

APPINSIGHTS_CONN = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")
if APPINSIGHTS_CONN:
    handler = AzureLogHandler(connection_string=APPINSIGHTS_CONN)
    logger.addHandler(handler)
    logger.info("app_startup", extra={
        "custom_dimensions": {
            "event_type": "startup",
            "status": "application_insights_connected"
        }
    })
else:
    logger.warning("app_startup", extra={
        "custom_dimensions": {
            "event_type": "startup",
            "status": "application_insights_not_configured"
        }
    })


# ============================================================
# FASTAPI INIT
# ============================================================

app = FastAPI(
    title="Bank Churn Prediction API",
    description="API de prédiction et monitoring du churn client",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

MODEL_PATH = os.getenv("MODEL_PATH", "model/churn_model.pkl")
model = None


@app.on_event("startup")
async def load_model():
    global model
    try:
        model = joblib.load(MODEL_PATH)
        logger.info("model_loaded", extra={
            "custom_dimensions": {
                "event_type": "model_load",
                "model_path": MODEL_PATH,
                "status": "success"
            }
        })
    except Exception as e:
        logger.error("model_load_failed", extra={
            "custom_dimensions": {
                "event_type": "model_load",
                "error": str(e)
            }
        })
        model = None


# ============================================================
# GENERAL ENDPOINTS
# ============================================================

@app.get("/", tags=["General"])
def root():
    return {
        "message": "Bank Churn Prediction API",
        "version": "1.0.0",
        "status": "running",
        "docs": "/docs"
    }


@app.get("/health", response_model=HealthResponse)
def health():
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return {"status": "healthy", "model_loaded": True}


# ============================================================
# PREDICTION ENDPOINTS
# ============================================================

@app.post("/predict", response_model=PredictionResponse)
def predict(features: CustomerFeatures):

    if model is None:
        raise HTTPException(status_code=503, detail="Model unavailable")

    try:
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

        proba = float(model.predict_proba(input_data)[0][1])
        prediction = int(proba > 0.5)

        risk = "Low" if proba < 0.3 else "Medium" if proba < 0.7 else "High"

        logger.info("prediction", extra={
            "custom_dimensions": {
                "event_type": "prediction",
                "endpoint": "/predict",
                "probability": proba,
                "prediction": prediction,
                "risk_level": risk
            }
        })

        return {
            "churn_probability": round(proba, 4),
            "prediction": prediction,
            "risk_level": risk
        }

    except Exception as e:
        logger.error("prediction_error", extra={
            "custom_dimensions": {
                "event_type": "prediction_error",
                "error": str(e)
            }
        })
        raise HTTPException(status_code=500, detail=str(e))
@app.post("/predict/batch")
def predict_batch(features_list: List[CustomerFeatures]):

    if model is None:
        raise HTTPException(status_code=503, detail="Model unavailable")

    try:
        predictions = []

        for features in features_list:
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

            proba = float(model.predict_proba(input_data)[0][1])
            prediction = int(proba > 0.5)

            predictions.append({
                "churn_probability": round(proba, 4),
                "prediction": prediction
            })

        logger.info("batch_prediction", extra={
            "custom_dimensions": {
                "event_type": "batch_prediction",
                "count": len(predictions)
            }
        })

        return {
            "predictions": predictions,
            "count": len(predictions)
        }

    except Exception as e:
        logger.error("batch_prediction_error", extra={
            "custom_dimensions": {
                "event_type": "batch_prediction_error",
                "error": str(e)
            }
        })
        raise HTTPException(status_code=500, detail=str(e))

# ============================================================
# DRIFT LOGGING TO APPLICATION INSIGHTS
# ============================================================

def log_drift_to_insights(drift_results: dict):

    total = len(drift_results)
    drifted = sum(1 for r in drift_results.values() if r.get("drift_detected"))
    percentage = round((drifted / total) * 100, 2) if total else 0

    risk = "LOW" if percentage < 20 else "MEDIUM" if percentage < 50 else "HIGH"

    logger.warning(
        "drift_detection",
        extra={
            "custom_dimensions": {   # ✅ OBLIGATOIRE
                "event_type": "drift_detection",
                "drift_percentage": percentage,
                "risk_level": risk
            }
        }
    )


    for feature, details in drift_results.items():
        if details.get("drift_detected"):
            logger.warning("feature_drift", extra={
                "custom_dimensions": {
                    "event_type": "feature_drift",
                    "feature_name": feature,
                    "p_value": float(details.get("p_value", 0)),
                    "statistic": float(details.get("statistic", 0)),
                    "type": details.get("type", "unknown")
                }
            })


# ============================================================
# DRIFT ENDPOINTS
# ============================================================

@app.post("/drift/check")
def check_drift(threshold: float = 0.05):

    try:
        results = detect_drift(
            reference_file="data/bank_churn.csv",
            production_file="data/production_data.csv",
            threshold=threshold
        )

        log_drift_to_insights(results)

        return {
            "status": "success",
            "features_analyzed": len(results),
            "features_drifted": sum(1 for r in results.values() if r["drift_detected"])
        }

    except Exception:
        tb = traceback.format_exc()
        logger.error("drift_error", extra={
            "custom_dimensions": {
                "event_type": "drift_error",
                "traceback": tb
            }
        })
        raise HTTPException(status_code=500, detail="Drift check failed")


@app.post("/drift/alert")
def manual_drift_alert(
    message: str = "Manual drift alert triggered",
    severity: str = "warning"
):
    logger.warning("manual_drift_alert", extra={
        "custom_dimensions": {
            "event_type": "manual_drift_alert",
            "alert_message": message,
            "severity": severity,
            "triggered_by": "api_endpoint"
        }
    })

    return {"status": "alert_sent"}







# from pydantic import BaseModel, Field
# from typing import List

# class CustomerFeatures(BaseModel):
#     """Schema pour les features d'un client"""
#     CreditScore: int = Field(..., ge=300, le=850, description="Score de credit")
#     Age: int = Field(..., ge=18, le=100, description="Age du client")
#     Tenure: int = Field(..., ge=0, le=10, description="Anciennete en annees")
#     Balance: float = Field(..., ge=0, description="Solde du compte")
#     NumOfProducts: int = Field(..., ge=1, le=4, description="Nombre de produits")
#     HasCrCard: int = Field(..., ge=0, le=1, description="Possession carte credit")
#     IsActiveMember: int = Field(..., ge=0, le=1, description="Membre actif")
#     EstimatedSalary: float = Field(..., ge=0, description="Salaire estime")
#     Geography_Germany: int = Field(..., ge=0, le=1, description="Client allemand")
#     Geography_Spain: int = Field(..., ge=0, le=1, description="Client espagnol")
    
#     class Config:
#         schema_extra = {
#             "example": {
#                 "CreditScore": 650,
#                 "Age": 35,
#                 "Tenure": 5,
#                 "Balance": 50000,
#                 "NumOfProducts": 2,
#                 "HasCrCard": 1,
#                 "IsActiveMember": 1,
#                 "EstimatedSalary": 75000,
#                 "Geography_Germany": 0,
#                 "Geography_Spain": 1
#             }
#         }

# class PredictionResponse(BaseModel):
#     """Schema pour la reponse de prediction"""
#     churn_probability: float = Field(..., description="Probabilite de churn (0-1)")
#     prediction: int = Field(..., description="Prediction binaire (0=reste, 1=part)")
#     risk_level: str = Field(..., description="Niveau de risque (Low/Medium/High)")

# class HealthResponse(BaseModel):
#     """Schema pour le health check"""
#     status: str
#     model_loaded: bool