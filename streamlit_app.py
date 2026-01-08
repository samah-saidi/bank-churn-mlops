import streamlit as st
import pandas as pd
import numpy as np
import joblib
import matplotlib.pyplot as plt
import seaborn as sns
import os

# Configuration de la page
st.set_page_config(
    page_title="Bank Churn Predictor",
    page_icon="🏦",
    layout="wide"
)

# Style CSS personnalisé pour une esthétique premium
st.markdown("""
    <style>
    .main {
        background-color: #f5f7f9;
    }
    .stButton>button {
        width: 100%;
        border-radius: 5px;
        height: 3em;
        background-color: #007bff;
        color: white;
        font-weight: bold;
    }
    .prediction-box {
        padding: 20px;
        border-radius: 10px;
        text-align: center;
        margin-top: 20px;
    }
    .churn {
        background-color: #ffe6e6;
        border: 1px solid #ff4d4d;
        color: #cc0000;
    }
    .no-churn {
        background-color: #e6ffed;
        border: 1px solid #28a745;
        color: #155724;
    }
    </style>
    """, unsafe_allow_html=True)

@st.cache_resource
def load_model():
    model_path = "model/churn_model.pkl"
    if os.path.exists(model_path):
        return joblib.load(model_path)
    return None

def main():
    st.title("🏦 Plateforme de Prédiction de Résiliation Bancaire")
    st.markdown("---")

    model = load_model()
    
    if model is None:
        st.error("Le modèle n'a pas été trouvé. Veuillez vous assurer que 'model/churn_model.pkl' existe.")
        return

    # Sidebar pour les entrées utilisateur
    st.sidebar.header("Informations Client")
    
    credit_score = st.sidebar.slider("Score de Crédit", 300, 850, 600)
    age = st.sidebar.slider("Âge", 18, 100, 40)
    tenure = st.sidebar.slider("Ancienneté (années)", 0, 10, 5)
    balance = st.sidebar.number_input("Solde du compte", min_value=0.0, value=50000.0, step=100.0)
    num_products = st.sidebar.selectbox("Nombre de produits", [1, 2, 3, 4], index=0)
    has_cr_card = st.sidebar.checkbox("Possède une carte de crédit", value=True)
    is_active = st.sidebar.checkbox("Membre actif", value=True)
    salary = st.sidebar.number_input("Salaire Estimé", min_value=0.0, value=100000.0, step=100.0)
    
    geography = st.sidebar.selectbox("Géographie", ["France", "Germany", "Spain"])

    # Préparation des données pour le modèle
    # Structure attendue : ['CreditScore', 'Age', 'Tenure', 'Balance', 'NumOfProducts', 
    # 'HasCrCard', 'IsActiveMember', 'EstimatedSalary', 'Geography_Germany', 
    # 'Geography_Spain']
    
    input_data = {
        'CreditScore': [credit_score],
        'Age': [age],
        'Tenure': [tenure],
        'Balance': [balance],
        'NumOfProducts': [num_products],
        'HasCrCard': [int(has_cr_card)],
        'IsActiveMember': [int(is_active)],
        'EstimatedSalary': [salary],
        'Geography_Germany': [1 if geography == "Germany" else 0],
        'Geography_Spain': [1 if geography == "Spain" else 0]
    }
    
    df_input = pd.DataFrame(input_data)

    # Affichage principal
    col1, col2 = st.columns([2, 1])

    with col1:
        st.subheader("📊 Analyse du Risque")
        if st.button("Lancer la Prédiction"):
            prediction_proba = model.predict_proba(df_input)[0][1]
            prediction = model.predict(df_input)[0]
            
            st.write(f"Probabilité de départ : **{prediction_proba:.2%}**")
            
            if prediction == 1:
                st.markdown(f'<div class="prediction-box churn"><h3>⚠️ Alerte : Risque de Churn Détecté</h3><p>Ce client a une forte probabilité de quitter la banque.</p></div>', unsafe_allow_html=True)
            else:
                st.markdown(f'<div class="prediction-box no-churn"><h3>✅ Client Fidèle</h3><p>Ce client a une faible probabilité de quitter la banque.</p></div>', unsafe_allow_html=True)
            
            # Gauge charts ou autres visuels pourraient être ajoutés ici
            st.progress(prediction_proba)

    with col2:
        st.subheader("💡 Recommandations")
        if 'prediction' in locals():
            if prediction == 1:
                st.info("- Proposer une offre promotionnelle personnalisée.\n- Appeler le client pour discuter de ses besoins.\n- Réviser les frais de compte.")
            else:
                st.success("- Continuer le programme de fidélité actuel.\n- Proposer de nouveaux produits financiers adaptés.")
        else:
            st.info("Lancez la prédiction pour voir les recommandations.")

    st.markdown("---")
    
    # Section Importance des caractéristiques
    if st.checkbox("Afficher l'importance des caractéristiques"):
        if hasattr(model, 'feature_importances_'):
            importances = model.feature_importances_
            feat_names = df_input.columns
            feat_importances = pd.Series(importances, index=feat_names).sort_values(ascending=True)
            
            fig, ax = plt.subplots()
            feat_importances.plot(kind='barh', ax=ax, color='#007bff')
            plt.title("Importance des Caractéristiques dans le Modèle")
            st.pyplot(fig)

if __name__ == "__main__":
    main()
