import pandas as pd
import numpy as np
from scipy import stats
import os

def detect_drift(reference_file: str, production_file: str, threshold: float = 0.05) -> dict:
    """
    Détecte le drift de données entre un fichier de référence et de production.
    Utilise le test de Kolmogorov-Smirnov pour les variables numériques.
    """
    if not os.path.exists(reference_file):
        raise FileNotFoundError(f"Référence non trouvée: {reference_file}")
    
    if not os.path.exists(production_file):
        # Si pas de données de production, on simule une absence de drift
        return {}

    ref_df = pd.read_csv(reference_file)
    prod_df = pd.read_csv(production_file)

    results = {}
    
    # On n'analyse que les colonnes communes
    features = [c for c in ref_df.columns if c in prod_df.columns]

    for feature in features:
        # Test KS pour les variables numériques
        if pd.api.types.is_numeric_dtype(ref_df[feature]):
            stat, p_value = stats.ks_2samp(ref_df[feature].dropna(), prod_df[feature].dropna())
            results[feature] = {
                "drift_detected": bool(p_value < threshold),
                "p_value": float(p_value),
                "statistic": float(stat),
                "type": "kolmogorov-smirnov"
            }
        else:
            # Pour les variables catégorielles (simplifié)
            # On pourrait utiliser un test Chi-deux ici
            results[feature] = {
                "drift_detected": False,
                "type": "categorical_skipped"
            }

    return results
