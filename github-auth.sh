#!/bin/bash
# github-auth.sh - Authentification GitHub App pour Dulien Orchestrator

# Configuration GitHub App
APP_ID="1837459"
INSTALLATION_ID="82600549"
PRIVATE_KEY_PATH="/home/florian/projets/dulien-orchestrator.2025-08-24.private-key.pem"

# Cache du token avec expiration
TOKEN_CACHE_FILE="/tmp/dulien-github-token"
TOKEN_CACHE_EXPIRY="/tmp/dulien-github-token-expiry"

generate_jwt_token() {
    local now=$(date +%s)
    local exp=$((now + 600))  # 10 minutes d'expiration
    
    # Header JWT
    local header='{"alg":"RS256","typ":"JWT"}'
    local header_b64=$(echo -n "$header" | base64 -w 0 | tr -d '=' | tr '/+' '_-')
    
    # Payload JWT
    local payload='{"iat":'$now',"exp":'$exp',"iss":"'$APP_ID'"}'
    local payload_b64=$(echo -n "$payload" | base64 -w 0 | tr -d '=' | tr '/+' '_-')
    
    # Signature
    local signature_input="${header_b64}.${payload_b64}"
    local signature=$(echo -n "$signature_input" | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" | base64 -w 0 | tr -d '=' | tr '/+' '_-')
    
    # JWT complet
    echo "${header_b64}.${payload_b64}.${signature}"
}

get_installation_token() {
    # Vérifier si token en cache et valide
    if [ -f "$TOKEN_CACHE_FILE" ] && [ -f "$TOKEN_CACHE_EXPIRY" ]; then
        local cache_expiry=$(cat "$TOKEN_CACHE_EXPIRY")
        local now=$(date +%s)
        
        if [ "$now" -lt "$cache_expiry" ]; then
            # Token en cache encore valide
            cat "$TOKEN_CACHE_FILE"
            return 0
        fi
    fi
    
    # Générer nouveau token
    local jwt_token=$(generate_jwt_token)
    
    # Échanger JWT contre Installation token
    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $jwt_token" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")
    
    # Extraire le token
    local installation_token=$(echo "$response" | jq -r '.token // empty')
    
    if [ -n "$installation_token" ] && [ "$installation_token" != "null" ]; then
        # Sauver en cache (expire dans 55 minutes)
        echo "$installation_token" > "$TOKEN_CACHE_FILE"
        echo $(($(date +%s) + 3300)) > "$TOKEN_CACHE_EXPIRY"
        
        echo "$installation_token"
        return 0
    else
        echo "❌ Erreur génération token GitHub App:" >&2
        echo "$response" >&2
        return 1
    fi
}

# Export function pour usage dans orchestrateur
export -f get_installation_token

# Si appelé directement, afficher le token
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    get_installation_token
fi